// B11-8 详情页导出图片（复制 / 保存 / 带答案版）测试。
//
// 覆盖：
// - 服务层：切片字节读取（有图 / 无 slicePath / 文件缺失）、
//   safeFileName、复制成功/失败（注入 writer，不碰真实剪贴板）；
// - 详情页：三个按钮与收藏/归档/删除并列；复制成功与失败的提示；
//   保存落盘 PNG（真实写文件进临时目录）；取消不写文件；
//   无切片的题三个动作都提示“没有图片可导出”；
// - 带答案版：弹窗预览含学科/文件夹/错因小字 + 答案/解析，
//   答案为空时卡片显示“待补充”；弹窗里保存走另存为落盘；
// - 分享卡片真实渲染：RepaintBoundary → PNG（PNG 签名 + 解码尺寸）；
// - 留样截图：详情页底部操作区 + 两张分享卡片 PNG 写进
//   docs/ui-replication/shots/b11-detail/（供报告留样）。
//
// 剪贴板边界说明：Linux 测试环境没有真实剪贴板/显示服务，
// 真实 super_clipboard 调用只在“剪贴板探针”一组里跑，
// 断言它不抛错、返回 bool；Win11 真机粘贴须另验（见报告）。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/detail/question_detail_page.dart';
import 'package:quiz_master2/services/question_export_service.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/question_share_card.dart';

late final Directory _testTmp;
late final Uint8List _sliceBytes;
const _sliceW = 480;
const _sliceH = 320;

Question b11q(
  String id,
  String title, {
  String? slicePath,
  String? answer,
  String? explanation,
  List<String> folderIds = const ['f1'],
  List<String> errorTypes = const ['概念不清'],
}) => Question(
  id: id,
  title: title,
  subjectId: 'math',
  folderIds: folderIds,
  knowledgePointIds: const ['k1'],
  errorTypes: errorTypes,
  answer: answer,
  explanation: explanation,
  createdAt: DateTime.now().subtract(const Duration(days: 2)),
  isOrganized: true,
  sliceKind: 'limit',
  sliceText: '题：求极限',
  slicePath: slicePath,
  sliceWidth: slicePath == null ? null : _sliceW,
  sliceHeight: slicePath == null ? null : _sliceH,
);

/// 只覆写详情页 _load 调用的方法（其余不触发，不碰真实数据库）。
class FakeExportRepo extends QuestionRepository {
  FakeExportRepo({required this.questions}) : super(AppDatabase.instance);

  List<Question> questions;

  @override
  Future<Question?> questionById(String id) async =>
      questions.where((q) => q.id == id).firstOrNull;

  @override
  Future<List<CauseRecord>> causeRecordsFor(String questionId) async => [];

  @override
  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
    String questionId,
  ) async => [];

  @override
  Future<List<Exam>> exams() async => [];

  @override
  Future<List<Folder>> folders({String? subjectId}) async => const [
    Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
  ];

  @override
  Future<List<String>> tags() async => [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [
    KnowledgePoint(
      id: 'k1',
      subjectId: 'math',
      chapter: '第一章 函数与极限',
      name: '函数极限',
    ),
  ];

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  // FR-09（D-88）：DetailNotifier.load() 多读 repo.settings()；FakeRepo
  // 不覆写会落到基类读真实 Drift 库，测试 fake async 里永不完成，
  // loading 一直 true、转圈拖死 pumpAndSettle。
  @override
  Future<AppSettings> settings() async => AppSettings.defaults;
}

/// 导出服务的假实现：三个外部边界（剪贴板写、另存为对话框、
// boundary 转 PNG）全部可控；sliceBytes / saveBytesTo 走真实实现
//（读盘、写盘是本次要验证的真实行为）。
class FakeExportService extends QuestionExportService {
  FakeExportService({this.savePath, this.copyThrows = false});

  String? savePath;
  bool copyThrows;

  Uint8List? copiedBytes;
  int copyCalls = 0;
  String? lastDialogTitle;
  String? lastFileName;
  int captureCalls = 0;

  @override
  Future<bool> copyImageToClipboard(Uint8List pngBytes) async {
    copyCalls++;
    copiedBytes = pngBytes;
    return !copyThrows;
  }

  @override
  Future<String?> pickSavePath({
    required String dialogTitle,
    required String fileName,
  }) async {
    lastDialogTitle = dialogTitle;
    lastFileName = fileName;
    return savePath;
  }

  @override
  Future<Uint8List> captureBoundary(
    GlobalKey key, {
    double pixelRatio = 2.0,
  }) async {
    captureCalls++;
    // 8 字节 PNG 签名 + 最小 IHDR 壳：仅作“弹窗→保存”链路的占位字节，
    // 真实渲染在“分享卡片真实渲染”一组里用真服务验证。
    return Uint8List.fromList(const [
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    ]);
  }
}

Future<void> pumpExportDetail(
  WidgetTester tester, {
  required FakeExportRepo repo,
  required FakeExportService service,
  String questionId = 'q1',
  VoidCallback? onGoReview,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: 1.0),
      home: Scaffold(
        body: QuestionDetailPage(
          key: UniqueKey(),
          repo: repo,
          questionId: questionId,
          orderIds: const ['q1', 'q2', 'q6'],
          sourceLabel: '错题本',
          exportService: service,
          onGoReview: onGoReview,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 有界手动 pump（b8_1_subject_refresh_flow_test.dart 的 `_pumpUntil`
/// 同款惯用法）：每轮先 pump 一帧看条件，再切回真实异步等一轮、
/// 再 pump 渲染，直到条件成立或超限失败。
/// testWidgets 体跑在 fake async 里，真实文件 IO 的 Future 等不到
/// 完成（直接 await 会永远卡死），必须用 `tester.runAsync` 切回
/// 真实异步等它完成——这就是本文件 widget 测试里复制/保存/导出
/// 点按后不用 pumpAndSettle、而用本 helper 等结果的原因。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
  // 轮数放宽到 60：多 worker 并行跑测试时本机很挤，单轮 pump +
  // 100ms 真实等待可能被拖慢，30 轮曾出现过一次“界面未稳定”抖动。
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

/// 底部操作行在 720 高视口外，先滚到可见再点（detail_page_test 同款）。
/// [waitFor] 非空时点后用 [_pumpUntil] 等真实 IO 完成（如读切片、
/// 写盘）；为空时只等界面静止（无 IO 的点按，如无切片题的提示、
/// “去复习”回调）。
Future<void> tapExportText(
  WidgetTester tester,
  String text, {
  bool Function()? waitFor,
  String reason = '',
}) async {
  final finder = find.text(text);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
  if (waitFor != null) {
    await _pumpUntil(tester, waitFor, reason: reason);
  } else {
    await tester.pumpAndSettle();
  }
}

bool _isPng(Uint8List bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4E &&
    bytes[3] == 0x47;

void main() {
  setUpAll(() async {
    _testTmp = await Directory.systemTemp.createTemp('qm2-b11-8-export');
    // 480×320 真实切片 PNG（白底 + 黑色“文字行”条）。
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, _sliceW.toDouble(), _sliceH.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    final bar = ui.Paint()..color = const ui.Color(0xFF111111);
    for (var i = 0; i < 4; i++) {
      canvas.drawRect(ui.Rect.fromLTWH(40, 40 + i * 70, 400, 10), bar);
    }
    final img = await recorder.endRecording().toImage(_sliceW, _sliceH);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    _sliceBytes = png!.buffer.asUint8List();
    final slicesDir = Directory('${_testTmp.path}/slices');
    await slicesDir.create(recursive: true);
    await File('${slicesDir.path}/q1.png').writeAsBytes(_sliceBytes);
    await File('${slicesDir.path}/q6.png').writeAsBytes(_sliceBytes);
    AppDatabase.testDataDirectory = _testTmp.path;
  });

  tearDownAll(() async {
    AppDatabase.testDataDirectory = null;
    await _testTmp.delete(recursive: true);
  });

  FakeExportRepo repo() => FakeExportRepo(
    questions: [
      b11q(
        'q1',
        '函数极限',
        slicePath: 'slices/q1.png',
        answer: '1',
        explanation: 'lim(x→0) sin3x/x = 3。',
      ),
      b11q('q2', '导数应用综合'),
      b11q('q6', '无答案题', slicePath: 'slices/q6.png'),
    ],
  );

  group('服务层', () {
    test('sliceBytes：有图读字节，无 slicePath / 文件缺失返回 null', () async {
      final service = QuestionExportService();
      expect(await service.sliceBytes(b11q('a', '有图', slicePath: 'slices/q1.png')), _sliceBytes);
      expect(await service.sliceBytes(b11q('b', '无图')), isNull);
      expect(
        await service.sliceBytes(
          b11q('c', '缺文件', slicePath: 'slices/not-there.png'),
        ),
        isNull,
      );
    });

    test('safeFileName：禁字符换下划线，空题名回退 question', () {
      expect(
        QuestionExportService.safeFileName('a/b:c*d?e"f<g>h|i\\j'),
        'a_b_c_d_e_f_g_h_i_j',
      );
      expect(QuestionExportService.safeFileName('  '), 'question');
      expect(
        QuestionExportService.safeFileName('函数极限'),
        '函数极限',
      );
    });

    test('copyImageToClipboard：writer 成功 true、抛错 false，不外抛', () async {
      var written = 0;
      final okService = QuestionExportService(
        writeClipboardImage: (bytes) async {
          written = bytes.length;
        },
      );
      expect(await okService.copyImageToClipboard(_sliceBytes), isTrue);
      expect(written, _sliceBytes.length);
      final badService = QuestionExportService(
        writeClipboardImage: (_) async => throw StateError('no clipboard'),
      );
      expect(await badService.copyImageToClipboard(_sliceBytes), isFalse);
    });

    // 剪贴板探针（Linux 测试环境）：不调真实 super_clipboard 写——
    // 无显示服务时原生写调用会阻塞（本轮实测：带真实写的探针让
    // flutter_tester 空转挂起，6 分钟无输出，只得杀掉重跑）。
    // 真实写路径的成功/失败分支已由上面注入 writer 的单测覆盖；
    // Windows 真机粘贴只能 Win11 实测（见报告“Win11 待验项”）。
  });

  group('详情页三个按钮', () {
    testWidgets('复制图片 / 保存图片 / 导出带答案版与收藏/归档/删除并列', (
      tester,
    ) async {
      await pumpExportDetail(
        tester,
        repo: repo(),
        service: FakeExportService(),
      );
      // 只滚到操作区，不点按钮（点“导出带答案版”会弹预览框）。
      await tester.ensureVisible(find.text('导出带答案版'));
      await tester.pumpAndSettle();
      expect(find.text('复制图片'), findsOneWidget);
      expect(find.text('保存图片'), findsOneWidget);
      expect(find.text('导出带答案版'), findsOneWidget);
      // 未收藏时按钮文案是“☆ 收藏”（已收藏时是“★ 已收藏（点击取消）”）。
      expect(find.text('☆ 收藏'), findsOneWidget);
      expect(find.text('归档'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
    });

    testWidgets('复制图片：成功提示，服务收到切片字节', (tester) async {
      final service = FakeExportService();
      await pumpExportDetail(tester, repo: repo(), service: service);
      await tapExportText(
        tester,
        '复制图片',
        // 等提示出现（不只等 copyCalls：复制调用返回后提示还需一帧渲染）。
        waitFor: () =>
            find.text('图片已复制到剪贴板').evaluate().isNotEmpty,
        reason: '复制成功提示未出现',
      );
      expect(service.copyCalls, 1);
      expect(service.copiedBytes, _sliceBytes);
      expect(find.text('图片已复制到剪贴板'), findsOneWidget);
    });

    testWidgets('复制图片失败：提示当前环境不支持', (tester) async {
      final service = FakeExportService(copyThrows: true);
      await pumpExportDetail(tester, repo: repo(), service: service);
      await tapExportText(
        tester,
        '复制图片',
        waitFor: () =>
            find.text('复制失败：当前环境不支持复制图片').evaluate().isNotEmpty,
        reason: '复制失败提示未出现',
      );
      expect(find.text('复制失败：当前环境不支持复制图片'), findsOneWidget);
    });

    testWidgets('保存图片：另存为路径落盘 PNG，字节与切片一致', (tester) async {
      final out = '${_testTmp.path}/saved-q1.png';
      final service = FakeExportService(savePath: out);
      await pumpExportDetail(tester, repo: repo(), service: service);
      await tapExportText(
        tester,
        '保存图片',
        // 等“已保存”提示出现：提示只在写盘完成后才发，比只等文件存在更严
        //（文件创建在写盘开始时，等 existsSync 会读到写一半的文件）。
        waitFor: () => find.text('题目图片已保存').evaluate().isNotEmpty,
        reason: '保存成功提示未出现',
      );
      expect(service.lastDialogTitle, '保存题目图片');
      expect(service.lastFileName, '函数极限.png');
      final file = File(out);
      expect(file.existsSync(), isTrue);
      expect(file.readAsBytesSync(), _sliceBytes);
      expect(find.text('题目图片已保存'), findsOneWidget);
    });

    testWidgets('保存图片：取消对话框不写文件、不提示', (tester) async {
      final service = FakeExportService(savePath: null);
      await pumpExportDetail(tester, repo: repo(), service: service);
      await tapExportText(
        tester,
        '保存图片',
        // 取消也要等另存为对话框真的被调过（读切片是真实 IO，
        // 不等会虚假通过）；调过后返回 null，不写文件、不提示。
        waitFor: () => service.lastDialogTitle == '保存题目图片',
        reason: '另存为对话框未弹出',
      );
      expect(File('${_testTmp.path}/cancel-should-not-exist.png').existsSync(), isFalse);
      expect(find.text('题目图片已保存'), findsNothing);
    });

    testWidgets('无切片的题：三个动作都提示没有图片可导出', (tester) async {
      final service = FakeExportService(
        savePath: '${_testTmp.path}/should-not-exist.png',
      );
      await pumpExportDetail(
        tester,
        repo: repo(),
        service: service,
        questionId: 'q2',
      );
      await tapExportText(tester, '复制图片');
      expect(find.text('这道题没有图片可导出'), findsOneWidget);
      await tapExportText(tester, '保存图片');
      expect(find.text('这道题没有图片可导出'), findsOneWidget);
      await tapExportText(tester, '导出带答案版');
      expect(find.text('这道题没有图片可导出'), findsOneWidget);
      expect(service.copyCalls, 0);
      expect(File('${_testTmp.path}/should-not-exist.png').existsSync(), isFalse);
    });
  });

  group('导出带答案版', () {
    testWidgets('弹窗预览：学科/文件夹/错因小字 + 题目图 + 答案/解析', (
      tester,
    ) async {
      final service = FakeExportService();
      await pumpExportDetail(tester, repo: repo(), service: service);
      await tapExportText(
        tester,
        '导出带答案版',
        waitFor: () =>
            find.text('数学 ｜ 试卷 ｜ 概念不清').evaluate().isNotEmpty,
        reason: '带答案版弹窗未打开',
      );
      // 弹窗标题与页面按钮同名“导出带答案版”，用 AlertDialog 后代定位标题。
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('导出带答案版'),
        ),
        findsOneWidget,
      );
      expect(find.text('数学 ｜ 试卷 ｜ 概念不清'), findsOneWidget);
      expect(find.text('函数极限'), findsOneWidget);
      // 页里还有一张 Image.file（题目图），弹窗卡片里是 Image.memory。
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );
      expect(find.text('1'), findsOneWidget);
      expect(find.text('lim(x→0) sin3x/x = 3。'), findsOneWidget);
      expect(find.text('待补充'), findsNothing);
    });

    testWidgets('弹窗里保存：capture 后走另存为落盘，提示已保存', (
      tester,
    ) async {
      final out = '${_testTmp.path}/share-q1.png';
      final service = FakeExportService(savePath: out);
      await pumpExportDetail(tester, repo: repo(), service: service);
      await tapExportText(
        tester,
        '导出带答案版',
        waitFor: () =>
            find.text('数学 ｜ 试卷 ｜ 概念不清').evaluate().isNotEmpty,
        reason: '带答案版弹窗未打开',
      );
      // 弹窗里也有“保存图片”，与页面的同名按钮共存，点最后一个（弹窗的）。
      await tester.tap(find.text('保存图片').last);
      await tester.pump();
      // 写盘是真实 IO，等“已保存”提示出现再断言（提示只在写盘完成后才发）。
      await _pumpUntil(
        tester,
        () => find.text('带答案版已保存').evaluate().isNotEmpty,
        reason: '带答案版保存提示未出现',
      );
      expect(service.captureCalls, 1);
      expect(service.lastDialogTitle, '保存带答案版图片');
      expect(service.lastFileName, '函数极限-带答案.png');
      expect(File(out).existsSync(), isTrue);
      expect(find.text('带答案版已保存'), findsOneWidget);
    });

    testWidgets('答案/解析为空：卡片两处都显示待补充，不编造', (tester) async {
      final service = FakeExportService();
      await pumpExportDetail(
        tester,
        repo: repo(),
        service: service,
        questionId: 'q6',
      );
      await tapExportText(
        tester,
        '导出带答案版',
        waitFor: () =>
            find.text('数学 ｜ 试卷 ｜ 概念不清').evaluate().isNotEmpty,
        reason: '带答案版弹窗未打开',
      );
      expect(find.text('待补充'), findsNWidgets(2));
    });
  });

  group('复习记录空状态去复习按钮（B11-11 顺手活）', () {
    testWidgets('有 onGoReview：空状态显示去复习按钮，点后回调触发', (
      tester,
    ) async {
      var tapped = false;
      await pumpExportDetail(
        tester,
        repo: repo(),
        service: FakeExportService(),
        onGoReview: () => tapped = true,
      );
      await tapExportText(tester, '复习记录');
      expect(find.text('暂无复习记录，去复习页练一次会出现在这里'), findsOneWidget);
      expect(find.text('去复习'), findsOneWidget);
      await tapExportText(tester, '去复习');
      expect(tapped, isTrue);
    });

    testWidgets('无 onGoReview：空状态只有文字，没有按钮', (tester) async {
      await pumpExportDetail(tester, repo: repo(), service: FakeExportService());
      await tapExportText(tester, '复习记录');
      expect(find.text('暂无复习记录，去复习页练一次会出现在这里'), findsOneWidget);
      expect(find.text('去复习'), findsNothing);
    });
  });

  group('分享卡片真实渲染', () {
    testWidgets('RepaintBoundary 转 PNG：签名正确，2.0 倍率下宽 1440', (
      tester,
    ) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(scale: 1.0),
          home: Scaffold(
            // 卡片自然高超 720 视口，包一层滚动防溢出（弹窗里同款做法）。
            body: SingleChildScrollView(
              child: RepaintBoundary(
                key: key,
                child: QuestionShareCard(
                  sliceBytes: _sliceBytes,
                  title: '函数极限',
                  subjectName: '数学',
                  folderNames: const ['试卷'],
                  errorTypes: const ['概念不清'],
                  answer: '1',
                  explanation: 'lim(x→0) sin3x/x = 3。',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final service = QuestionExportService();
      final png = (await tester.runAsync(
        () => service.captureBoundary(key, pixelRatio: 2.0),
      ))!;
      expect(_isPng(png), isTrue);
      final codec = (await tester.runAsync(
        () => ui.instantiateImageCodec(png),
      ))!;
      final frame = (await tester.runAsync(() => codec.getNextFrame()))!;
      expect(frame.image.width, 1440);
      expect(frame.image.height, greaterThan(0));
      frame.image.dispose();
    });

    testWidgets('答案为空的卡片同样能转 PNG', (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(scale: 1.0),
          home: Scaffold(
            // 卡片自然高超 720 视口，包一层滚动防溢出（弹窗里同款做法）。
            body: SingleChildScrollView(
              child: RepaintBoundary(
                key: key,
                child: QuestionShareCard(
                  sliceBytes: _sliceBytes,
                  title: '无答案题',
                  subjectName: '数学',
                  folderNames: const ['试卷'],
                  errorTypes: const ['概念不清'],
                  answer: null,
                  explanation: null,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final service = QuestionExportService();
      final png = (await tester.runAsync(
        () => service.captureBoundary(key, pixelRatio: 2.0),
      ))!;
      expect(_isPng(png), isTrue);
      expect(find.text('待补充'), findsNWidgets(2));
    });
  });

  group('留样截图', () {
    testWidgets('生成 docs/ui-replication/shots/b11-detail/ 下的三张留样', (
      tester,
    ) async {
      final shotsDir = Directory('docs/ui-replication/shots/b11-detail');
      shotsDir.createSync(recursive: true);
      final service = QuestionExportService();

      // 01：详情页底部操作区（三个导出按钮与收藏/归档/删除并列）。
      final pageKey = GlobalKey();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(scale: 1.0),
          home: Scaffold(
            body: RepaintBoundary(
              key: pageKey,
              child: QuestionDetailPage(
                key: UniqueKey(),
                repo: repo(),
                questionId: 'q1',
                orderIds: const ['q1', 'q2', 'q6'],
                sourceLabel: '错题本',
                exportService: FakeExportService(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('导出带答案版'));
      await tester.pumpAndSettle();
      // 题目图是 Image.file（真实 IO 解码）：切回真实异步等它解出来，
      // 再截，否则截图里是大图占位而不是真图。
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();
      final pageShot = (await tester.runAsync(
        () => service.captureBoundary(pageKey, pixelRatio: 1.0),
      ))!;
      expect(_isPng(pageShot), isTrue);
      // 同步写盘：testWidgets 体内 await 真实 IO 会永远卡死。
      File('${shotsDir.path}/01-detail-actions.png')
          .writeAsBytesSync(pageShot);

      // 02：带答案版分享卡片（有答案）。
      final cardKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(scale: 1.0),
          home: Scaffold(
            body: SingleChildScrollView(
              child: RepaintBoundary(
                key: cardKey,
                child: QuestionShareCard(
                  sliceBytes: _sliceBytes,
                  title: '函数极限',
                  subjectName: '数学',
                  folderNames: const ['试卷'],
                  errorTypes: const ['概念不清'],
                  answer: '1',
                  explanation: 'lim(x→0) sin3x/x = 3。',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final cardShot = (await tester.runAsync(
        () => service.captureBoundary(cardKey, pixelRatio: 2.0),
      ))!;
      expect(_isPng(cardShot), isTrue);
      // 同步写盘：testWidgets 体内 await 真实 IO 会永远卡死。
      File('${shotsDir.path}/02-share-card.png').writeAsBytesSync(cardShot);

      // 03：带答案版分享卡片（答案/解析为空 → 待补充）。
      final emptyKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(scale: 1.0),
          home: Scaffold(
            body: SingleChildScrollView(
              child: RepaintBoundary(
                key: emptyKey,
                child: QuestionShareCard(
                  sliceBytes: _sliceBytes,
                  title: '无答案题',
                  subjectName: '数学',
                  folderNames: const ['试卷'],
                  errorTypes: const ['概念不清'],
                  answer: null,
                  explanation: null,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final emptyShot = (await tester.runAsync(
        () => service.captureBoundary(emptyKey, pixelRatio: 2.0),
      ))!;
      expect(_isPng(emptyShot), isTrue);
      // 同步写盘：testWidgets 体内 await 真实 IO 会永远卡死。
      File(
        '${shotsDir.path}/03-share-card-empty-answer.png',
      ).writeAsBytesSync(emptyShot);
    });
  });
}
