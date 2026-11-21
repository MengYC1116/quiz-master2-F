// 十五批 M3-F：逐题来源行「学科 / 文件夹 / 考试名」补齐
// （PLAN §1.1；M1-DESIGN.md §7 整单规则不变）。
//
// 覆盖：
// - 格式化口径：三段齐全、多文件夹“、”连接、无文件夹/无考试省段；
// - 生产解析：Drift 批量读（题目行 + 文件夹名 + 考试名各一次查询），
//   顺序保持、缺题 null、已删文件夹/考试按“无”计；
// - 快照冻结：条目带文件夹/考试名；快照后改文件夹不影响本次导出；
//   建成过程中改文件夹 → 终态复核整单失效；
// - C 路线渲染：来源行只印首段、逐题各印各的；
// - A 路线规划与端到端：来源行高度计入规划（恰好放得下边界翻页）、
//   BROKEN 占位块同口径、buildDocument 页数与规划一致；
// - 服务级：C/A 两路线经 sourceTextFor 拼出同一口径的来源行；
//   多学科/多文件夹整单信息区仍用“多学科”/“多文件夹”；
// - 答案版：题目区来源行与练习版同一口径（两版题号一致）。
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/services/pdf_export/a_content_builder.dart';
import 'package:quiz_master2/services/pdf_export/c_content_builder.dart';
import 'package:quiz_master2/services/pdf_export/drift_export_source.dart';
import 'package:quiz_master2/services/pdf_export/export_filename.dart';
import 'package:quiz_master2/services/pdf_export/export_question_record.dart';
import 'package:quiz_master2/services/pdf_export/export_route.dart';
import 'package:quiz_master2/services/pdf_export/export_snapshot.dart';
import 'package:quiz_master2/services/pdf_export/export_versions.dart';
import 'package:quiz_master2/services/pdf_export/pdf_document_builder.dart';
import 'package:quiz_master2/services/pdf_export/pdf_export_service.dart';
import 'package:quiz_master2/services/pdf_export/pdf_font.dart';
import 'package:quiz_master2/services/pdf_export/snapshot_exceptions.dart';
import 'package:quiz_master2/services/pdf_export/text_pagination.dart';

import 'b15_m1b_fake_source.dart';

/// 从 PDF 字节里读 /Type /Pages 的 /Count（M1-D 测试同款）。
int pdfPageCount(Uint8List bytes) {
  final text = String.fromCharCodes(bytes);
  final match = RegExp(r'/Type\s*/Pages[\s\S]{0,400}?/Count\s+(\d+)')
      .firstMatch(text);
  if (match == null) throw StateError('PDF 里找不到 /Count');
  return int.parse(match.group(1)!);
}

/// 通用 widget 树遍历（M1-C 测试同款）。
void _walk(pw.Widget w, void Function(pw.Widget) visit) {
  visit(w);
  if (w is pw.RichText) {
    void walkSpan(pw.InlineSpan span) {
      if (span is pw.WidgetSpan) {
        _walk(span.child, visit);
      } else if (span is pw.TextSpan) {
        for (final c in span.children ?? const <pw.InlineSpan>[]) {
          walkSpan(c);
        }
      }
    }

    walkSpan(w.text);
  } else if (w is pw.Column) {
    for (final c in w.children) {
      _walk(c, visit);
    }
  } else if (w is pw.Inseparable) {
    final c = w.child;
    if (c != null) _walk(c, visit);
  } else if (w is pw.Container) {
    final c = w.child;
    if (c != null) _walk(c, visit);
  } else if (w is pw.SizedBox) {
    final c = w.child;
    if (c != null) _walk(c, visit);
  } else if (w is pw.SingleChildWidget) {
    final c = w.child;
    if (c != null) _walk(c, visit);
  } else if (w is pw.MultiChildWidget) {
    for (final c in w.children) {
      _walk(c, visit);
    }
  }
}

/// 收集 widget 子树里全部文本（M1-C 测试同款）。
List<String> _texts(pw.Widget widget) {
  final out = <String>[];
  void collectSpan(pw.InlineSpan span) {
    if (span is pw.TextSpan) {
      if (span.text != null) out.add(span.text!);
      for (final c in span.children ?? const <pw.InlineSpan>[]) {
        collectSpan(c);
      }
    }
  }

  _walk(widget, (w) {
    if (w is pw.RichText) collectSpan(w.text);
  });
  return out;
}

/// 中文长题干（M1-C 测试同款，约 46 字 / 行）。
String _longStem(int chars) {
  const sentence = '已知函数满足下列条件：设实数满足不等式关系，且区间端点均为整数，'
      '试求满足条件的取值范围，并给出完整的推理过程。';
  final buf = StringBuffer();
  while (buf.length < chars) {
    buf.write(sentence);
  }
  return buf.toString().substring(0, chars);
}

Uint8List? _fontBytesCache;

Future<Uint8List> _fontBytes() async =>
    _fontBytesCache ??= await File(
      'assets/fonts/NotoSansSC-Regular.ttf',
    ).readAsBytes();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempRoot;
  late FakeExportQuestionSource source;
  late pw.Font font;
  late PdfExportDocumentBuilder docBuilder;
  late CTextPaginator paginator;

  setUpAll(() async {
    font = await PdfExportFont.loadBundledFont();
    docBuilder = PdfExportDocumentBuilder(font: font);
    final splitter = TextPainterSplitter();
    await splitter.ensureFontLoaded();
    paginator = CTextPaginator(splitter: splitter);
  });

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('b15-m3f-');
    source = FakeExportQuestionSource();
  });

  tearDown(() async {
    if (tempRoot.existsSync()) {
      await tempRoot.delete(recursive: true);
    }
  });

  PdfExportMetadata metadata() =>
      const PdfExportMetadata(title: '错题本导出 · 数学');
  PdfExportHeaderInfo header() =>
      const PdfExportHeaderInfo(subjectName: '数学', exportDateText: '2026-11-20');
  PdfExportInfo info(int count) => PdfExportInfo(
        filterText: '数学 · 全部文件夹',
        questionCount: count,
        exportDateText: '2026-11-20',
        sortText: '默认排序',
        routeText: 'A 路线',
      );

  Future<ExportSnapshot> buildA(
    List<String> ids, {
    List<ExcludedQuestion> excluded = const [],
  }) {
    return ExportSnapshot.fromSelection(
      ids: ids,
      excluded: excluded,
      route: ExportRoute.a,
      filterText: '全部',
      sortText: '默认排序',
      source: source,
      tempRoot: tempRoot,
    );
  }

  void addSliceQuestion(String id, {required int w, required int h}) {
    source.records[id] = choiceRecord(id: id, sliceWidth: w, sliceHeight: h);
    source.slices[id] = makePng(w, h);
  }

  /// 两道带来源信息的选择题（C 路线服务级测试用）。
  void addCSourceRecords() {
    source.records['q1'] = choiceRecord(
      id: 'q1',
      subjectId: 'math',
      folderNames: const ['高数', '线代'],
      examName: '期中考试',
      answer: 'A',
      explanation: '解析一',
    );
    source.records['q2'] = choiceRecord(
      id: 'q2',
      subjectId: 'english',
      folderNames: const ['作业本'],
      answer: 'B',
      explanation: '解析二',
    );
    source.slices['q1'] = makePng(800, 200);
    source.slices['q2'] = makePng(800, 200);
  }

  const subjectNames = {'math': '数学', 'english': '英语'};

  /// 生产口径的来源行拼法（wrongbook_page 回调同款）。
  String Function(ExportQuestionRecord) sourceTextFor({
    Map<String, String>? seen,
  }) {
    return (record) {
      final text = formatExportSourceText(
        subjectName: subjectNames[record.subjectId] ?? '',
        folderNames: record.folderNames,
        examName: record.examName,
      );
      if (seen != null) seen[record.id] = text;
      return text;
    };
  }

  PdfExportService service({
    required bool hasKey,
    Map<String, String>? seen,
  }) => PdfExportService(
    source: source,
    hasApiKey: () async => hasKey,
    fontBytesLoader: _fontBytes,
    tempRoot: tempRoot,
    subjectName: '多学科',
    sourceTextFor: sourceTextFor(seen: seen),
  );

  group('格式化口径 formatExportSourceText', () {
    test('三段齐全：学科 / 文件夹 / 考试名', () {
      expect(
        formatExportSourceText(
          subjectName: '数学',
          folderNames: const ['高数'],
          examName: '期中考试',
        ),
        '数学 / 高数 / 期中考试',
      );
    });

    test('文件夹多个时用“、”连接全部，不用“多文件夹”代替', () {
      expect(
        formatExportSourceText(
          subjectName: '数学',
          folderNames: const ['高数', '线代', '习题册'],
          examName: '期中考试',
        ),
        '数学 / 高数、线代、习题册 / 期中考试',
      );
    });

    test('无文件夹时省掉该段', () {
      expect(
        formatExportSourceText(
          subjectName: '数学',
          folderNames: const [],
          examName: '期中考试',
        ),
        '数学 / 期中考试',
      );
    });

    test('无考试时省掉该段', () {
      expect(
        formatExportSourceText(
          subjectName: '数学',
          folderNames: const ['高数'],
        ),
        '数学 / 高数',
      );
    });

    test('无文件夹无考试时只剩学科', () {
      expect(
        formatExportSourceText(subjectName: '数学', folderNames: const []),
        '数学',
      );
    });

    test('空白段一律省掉，不留空段与多余分隔', () {
      expect(
        formatExportSourceText(
          subjectName: ' 数学 ',
          folderNames: const ['  ', '高数', ''],
          examName: '  ',
        ),
        '数学 / 高数',
      );
      expect(
        formatExportSourceText(subjectName: '', folderNames: const ['高数']),
        '高数',
      );
    });
  });

  group('生产解析 DriftExportQuestionSource.fetchQuestions', () {
    late QuizDatabase db;

    setUp(() async {
      db = await AppDatabase.instance.db;
      await db
          .into(db.folders)
          .insert(
            FoldersCompanion.insert(id: 'm3f-f1', name: '高数', subjectId: 'math'),
          );
      await db
          .into(db.folders)
          .insert(
            FoldersCompanion.insert(id: 'm3f-f2', name: '线代', subjectId: 'math'),
          );
      await db
          .into(db.folders)
          .insert(
            FoldersCompanion.insert(id: 'm3f-f3', name: '力学', subjectId: 'physics'),
          );
      await db
          .into(db.exams)
          .insert(ExamsCompanion.insert(id: 'm3f-e1', name: '期中考试'));
      await db
          .into(db.exams)
          .insert(ExamsCompanion.insert(id: 'm3f-e2', name: '期末考试'));
      await db
          .into(db.questions)
          .insert(
            QuestionsCompanion.insert(
              id: 'm3f-q1',
              title: '多文件夹题',
              subjectId: 'math',
              createdAt: 0,
              folderIds: const Value(['m3f-f1', 'm3f-f2']),
              examId: const Value('m3f-e1'),
            ),
          );
      await db
          .into(db.questions)
          .insert(
            QuestionsCompanion.insert(
              id: 'm3f-q2',
              title: '无文件夹无考试题',
              subjectId: 'math',
              createdAt: 0,
              folderIds: const Value([]),
            ),
          );
      await db
          .into(db.questions)
          .insert(
            QuestionsCompanion.insert(
              id: 'm3f-q3',
              title: '已删文件夹与考试题',
              subjectId: 'physics',
              createdAt: 0,
              folderIds: const Value(['m3f-f3', 'm3f-deleted-folder']),
              examId: const Value('m3f-deleted-exam'),
            ),
          );
    });

    tearDown(() async {
      for (final id in ['m3f-q1', 'm3f-q2', 'm3f-q3']) {
        await (db.delete(db.questions)..where((t) => t.id.equals(id))).go();
      }
      for (final id in ['m3f-f1', 'm3f-f2', 'm3f-f3']) {
        await (db.delete(db.folders)..where((t) => t.id.equals(id))).go();
      }
      for (final id in ['m3f-e1', 'm3f-e2']) {
        await (db.delete(db.exams)..where((t) => t.id.equals(id))).go();
      }
    });

    test('批量解析：文件夹名按顺序、考试名单个、顺序保持、缺题 null', () async {
      const src = DriftExportQuestionSource();
      final rows = await src.fetchQuestions(
        const ['m3f-q1', 'm3f-missing', 'm3f-q2', 'm3f-q3'],
      );
      expect(rows.length, 4);
      expect(rows[1], isNull);
      expect(rows[0]!.folderNames, ['高数', '线代']);
      expect(rows[0]!.examName, '期中考试');
      expect(rows[2]!.folderNames, isEmpty);
      expect(rows[2]!.examName, isNull);
      // 已删的文件夹跳过、已删的考试按无考试计。
      expect(rows[3]!.folderNames, ['力学']);
      expect(rows[3]!.examName, isNull);
      // 拼出的来源行与口径一致。
      expect(
        formatExportSourceText(
          subjectName: '数学',
          folderNames: rows[0]!.folderNames,
          examName: rows[0]!.examName,
        ),
        '数学 / 高数、线代 / 期中考试',
      );
    });

    test('单题入口与批量一致', () async {
      const src = DriftExportQuestionSource();
      final one = await src.fetchQuestion('m3f-q1');
      expect(one, isNotNull);
      expect(one!.folderNames, ['高数', '线代']);
      expect(one.examName, '期中考试');
      expect(await src.fetchQuestion('m3f-missing'), isNull);
    });
  });

  group('快照冻结', () {
    test('A 路线条目冻结文件夹与考试名（可印题）', () async {
      source.records['q1'] = choiceRecord(
        id: 'q1',
        folderNames: const ['高数', '线代'],
        examName: '期中考试',
      );
      source.slices['q1'] = makePng(2126, 530);
      final snapshot = await buildA(const ['q1']);
      addTearDown(snapshot.dispose);
      expect(snapshot.entries.single.folderNames, ['高数', '线代']);
      expect(snapshot.entries.single.examName, '期中考试');
    });

    test('BROKEN 与 SKIPPED 条目同样冻结文件夹与考试名', () async {
      source.records['q1'] = choiceRecord(
        id: 'q1',
        folderNames: const ['高数'],
        examName: '期中考试',
      );
      source.unavailableSlices.add('q1');
      source.records['q2'] = choiceRecord(
        id: 'q2',
        ocrRaw: null,
        folderNames: const ['线代'],
        examName: '期末考试',
      );
      source.slices['q2'] = makePng(800, 200);
      final snapshotA = await buildA(const ['q1']);
      addTearDown(snapshotA.dispose);
      expect(snapshotA.entries.single.outcome, SnapshotOutcome.broken);
      expect(snapshotA.entries.single.folderNames, ['高数']);
      expect(snapshotA.entries.single.examName, '期中考试');
      final snapshotC = await ExportSnapshot.fromSelection(
        ids: const ['q2'],
        excluded: const [],
        route: ExportRoute.c,
        filterText: '全部',
        sortText: '默认排序',
        source: source,
        tempRoot: tempRoot,
      );
      addTearDown(snapshotC.dispose);
      expect(snapshotC.entries.single.outcome, SnapshotOutcome.skipped);
      expect(snapshotC.entries.single.folderNames, ['线代']);
      expect(snapshotC.entries.single.examName, '期末考试');
    });

    test('快照后改文件夹/改考试名不影响本次导出', () async {
      source.records['q1'] = choiceRecord(
        id: 'q1',
        folderNames: const ['高数'],
        examName: '期中考试',
      );
      source.slices['q1'] = makePng(2126, 530);
      final snapshot = await buildA(const ['q1']);
      addTearDown(snapshot.dispose);
      // 快照建成后改文件夹归属与考试名（换记录对象）。
      source.records['q1'] = choiceRecord(
        id: 'q1',
        folderNames: const ['线代', '习题册'],
        examName: '期末考试',
      );
      expect(snapshot.entries.single.folderNames, ['高数']);
      expect(snapshot.entries.single.examName, '期中考试');
      // 源本身确实已改（对照：不是没改成）。
      final current = await source.fetchQuestion('q1');
      expect(current!.folderNames, ['线代', '习题册']);
      expect(current.examName, '期末考试');
    });

    test('建成过程中改文件夹 → 终态复核整单失效', () async {
      source.records['q1'] = choiceRecord(
        id: 'q1',
        folderNames: const ['高数'],
        examName: '期中考试',
      );
      source.slices['q1'] = makePng(2126, 530);
      var fetchCalls = 0;
      source.fetchOverride = (id) {
        fetchCalls++;
        if (fetchCalls == 1) return source.records[id];
        // 第二次读（终态复核）时文件夹已被改。
        return choiceRecord(
          id: id,
          folderNames: const ['线代'],
          examName: '期中考试',
        );
      };
      await expectLater(
        buildA(const ['q1']),
        throwsA(isA<SnapshotChangedException>()),
      );
    });

    test('批量接口默认实现：顺序保持、缺题 null', () async {
      source.records['q1'] = choiceRecord(id: 'q1');
      source.records['q2'] = choiceRecord(id: 'q2');
      final rows = await source.fetchQuestions(const ['q2', 'nope', 'q1']);
      expect(rows.map((r) => r?.id).toList(), ['q2', null, 'q1']);
    });
  });

  group('C 路线渲染：来源行', () {
    test('两道题各印各的来源行，只在首段出现一次', () async {
      final plan = paginator.paginate([
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          sourceText: '数学 / 高数、线代 / 期中考试',
          blocks: [CLayoutParagraph(CParagraph(text: _longStem(100)))],
        ),
        CPaginableQuestion(
          questionIndex: 1,
          displayNumber: 2,
          sourceText: '英语 / 作业本',
          blocks: [CLayoutParagraph(CParagraph(text: _longStem(80)))],
        ),
      ]);
      final children = await CContentBuilder.buildChildren(
        plan: plan,
        tempDir: tempRoot,
        questions: const [
          CBuildQuestion(
            questionIndex: 0,
            questionId: 'q0',
            title: '第 1 题',
            sourceText: '数学 / 高数、线代 / 期中考试',
          ),
          CBuildQuestion(
            questionIndex: 1,
            questionId: 'q1',
            title: '第 2 题',
            sourceText: '英语 / 作业本',
          ),
        ],
        documentBuilder: docBuilder,
        info: info(2),
      );
      expect(children.length, 3);
      final t1 = _texts(children[1]);
      expect(t1, contains('第 1 题'));
      expect(t1, contains('数学 / 高数、线代 / 期中考试'));
      expect(t1.where((t) => t == '数学 / 高数、线代 / 期中考试').length, 1);
      final t2 = _texts(children[2]);
      expect(t2, contains('第 2 题'));
      expect(t2, contains('英语 / 作业本'));
      // 不串题：第二题不含第一题的来源行。
      expect(t2, isNot(contains('数学 / 高数、线代 / 期中考试')));
    });

    test('无考试省段的来源行照常渲染', () async {
      final plan = paginator.paginate([
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          sourceText: '数学 / 高数',
          blocks: [CLayoutParagraph(CParagraph(text: _longStem(100)))],
        ),
      ]);
      final children = await CContentBuilder.buildChildren(
        plan: plan,
        tempDir: tempRoot,
        questions: const [
          CBuildQuestion(
            questionIndex: 0,
            questionId: 'q0',
            title: '第 1 题',
            sourceText: '数学 / 高数',
          ),
        ],
        documentBuilder: docBuilder,
        info: info(1),
      );
      expect(_texts(children[1]), contains('数学 / 高数'));
    });
  });

  group('A 路线规划：来源行高度', () {
    test('来源行文字只带在首段，续段不重复', () {
      final plan = AContentBuilder.planQuestions(
        questions: const [
          APlanQuestion(
            questionId: 'q1',
            questionNumber: 1,
            cappedWidthPx: 1000,
            cappedHeightPx: 3000,
            sourceText: '数学 / 高数 / 期中考试',
          ),
        ],
      );
      final segments = [
        for (final page in plan.pages)
          for (final item in page.items)
            if (item is APlannedSegment) item,
      ];
      expect(segments.length, greaterThan(1));
      expect(segments.first.sourceText, '数学 / 高数 / 期中考试');
      for (final seg in segments.skip(1)) {
        expect(seg.sourceText, isEmpty);
      }
    });

    test('恰好放得下边界：加来源行翻页，不加不翻', () {
      // 取一题恰好在“无来源行放得下、有来源行放不下”的窗口内。
      final avail = AContentBuilder.firstPageAvailableHeightPt;
      final scale =
          PdfExportGeometry.contentWidthPt / 1000;
      final displayH = avail - kAQuestionNumberHeightPt - 7;
      final heightPx = (displayH / scale).round();
      final actualDisplayH = heightPx * scale;
      // 校验窗口（若几何改了，测试在 setup 处先失败，不静默误判）。
      expect(actualDisplayH, lessThan(avail - kAQuestionNumberHeightPt));
      expect(
        actualDisplayH,
        greaterThan(
          avail - kAQuestionNumberHeightPt - kASourceLineHeightPt,
        ),
      );
      final without = AContentBuilder.planQuestions(
        questions: [
          APlanQuestion(
            questionId: 'q1',
            questionNumber: 1,
            cappedWidthPx: 1000,
            cappedHeightPx: heightPx,
          ),
        ],
      );
      expect(without.totalPages, 1);
      final withSource = AContentBuilder.planQuestions(
        questions: [
          APlanQuestion(
            questionId: 'q1',
            questionNumber: 1,
            cappedWidthPx: 1000,
            cappedHeightPx: heightPx,
            sourceText: '数学 / 高数 / 期中考试',
          ),
        ],
      );
      expect(withSource.totalPages, 2);
    });

    test('BROKEN 占位块同口径：9 个占位块加来源行翻页', () {
      final broken = [
        for (var i = 0; i < 9; i++)
          APlanQuestion(
            questionId: 'b$i',
            questionNumber: i + 1,
            cappedWidthPx: 0,
            cappedHeightPx: 0,
            isBroken: true,
            brokenReason: '源切片缺失',
          ),
      ];
      expect(
        AContentBuilder.planQuestions(questions: broken).totalPages,
        1,
      );
      final withSource = [
        for (var i = 0; i < 9; i++)
          APlanQuestion(
            questionId: 'b$i',
            questionNumber: i + 1,
            cappedWidthPx: 0,
            cappedHeightPx: 0,
            isBroken: true,
            brokenReason: '源切片缺失',
            sourceText: '数学 / 高数 / 期中考试',
          ),
      ];
      final plan = AContentBuilder.planQuestions(questions: withSource);
      expect(plan.totalPages, 2);
      final blocks = [
        for (final page in plan.pages)
          for (final item in page.items)
            if (item is APlannedBroken) item,
      ];
      expect(blocks.length, 9);
      expect(
        blocks.map((b) => b.sourceText).toSet(),
        {'数学 / 高数 / 期中考试'},
      );
    });
  });

  group('A 路线端到端 buildDocument', () {
    test('来源行印出：页数与规划一致（不溢出容器）', () async {
      addSliceQuestion('q1', w: 2126, h: 530);
      addSliceQuestion('q2', w: 2126, h: 530);
      final snapshot = await buildA(const ['q1', 'q2']);
      addTearDown(snapshot.dispose);
      final result = await AContentBuilder.buildDocument(
        snapshot: snapshot,
        documentBuilder: docBuilder,
        metadata: metadata(),
        headerInfo: header(),
        info: info(2),
        sourceTextById: const {
          'q1': '数学 / 高数 / 期中考试',
          'q2': '数学 / 线代',
        },
      );
      final bytes = await docBuilder.savePdf(result.document);
      expect(_startsWithPdfHeader(bytes), isTrue);
      expect(pdfPageCount(bytes), result.plan.totalPages);
      expect(
        result.questions.map((q) => q.questionNumber).toList(),
        [1, 2],
      );
    });

    test('来源行把恰好放得下的题顶到下一页（渲染与规划一致）', () async {
      final avail = AContentBuilder.firstPageAvailableHeightPt;
      final scale = PdfExportGeometry.contentWidthPt / 1000;
      final heightPx =
          ((avail - kAQuestionNumberHeightPt - 7) / scale).round();
      addSliceQuestion('q1', w: 1000, h: heightPx);
      final snapshot = await buildA(const ['q1']);
      addTearDown(snapshot.dispose);
      final without = await AContentBuilder.buildDocument(
        snapshot: snapshot,
        documentBuilder: docBuilder,
        metadata: metadata(),
        headerInfo: header(),
        info: info(1),
      );
      final bytesWithout = await docBuilder.savePdf(without.document);
      expect(pdfPageCount(bytesWithout), 1);
      final withSource = await AContentBuilder.buildDocument(
        snapshot: snapshot,
        documentBuilder: docBuilder,
        metadata: metadata(),
        headerInfo: header(),
        info: info(1),
        sourceTextById: const {'q1': '数学 / 高数 / 期中考试'},
      );
      final bytesWith = await docBuilder.savePdf(withSource.document);
      expect(pdfPageCount(bytesWith), 2);
      expect(pdfPageCount(bytesWith), withSource.plan.totalPages);
    });

    test('BROKEN 占位块带来源行仍可生成', () async {
      source.records['q1'] = choiceRecord(
        id: 'q1',
        folderNames: const ['高数'],
        examName: '期中考试',
      );
      source.unavailableSlices.add('q1');
      final snapshot = await buildA(const ['q1']);
      addTearDown(snapshot.dispose);
      final result = await AContentBuilder.buildDocument(
        snapshot: snapshot,
        documentBuilder: docBuilder,
        metadata: metadata(),
        headerInfo: header(),
        info: info(1),
        sourceTextById: const {'q1': '数学 / 高数 / 期中考试'},
      );
      final bytes = await docBuilder.savePdf(result.document);
      expect(pdfPageCount(bytes), result.plan.totalPages);
      expect(result.questions.single.status.name, 'broken');
    });
  });

  group('服务级：两路线同一口径', () {
    test('C 路线：来源行按本题实际信息拼，不取首题代表', () async {
      addCSourceRecords();
      final seen = <String, String>{};
      final result = await service(hasKey: true, seen: seen).generate(
        ids: const ['q1', 'q2'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
      );
      expect(result.route, ExportRoute.c);
      expect(_startsWithPdfHeader(result.pdfBytes), isTrue);
      expect(result.report.conservationError(), isNull);
      expect(seen['q1'], '数学 / 高数、线代 / 期中考试');
      expect(seen['q2'], '英语 / 作业本');
    });

    test('A 路线：来源行与 C 路线同一口径', () async {
      addCSourceRecords();
      final seen = <String, String>{};
      final result = await service(hasKey: false, seen: seen).generate(
        ids: const ['q1', 'q2'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
      );
      expect(result.route, ExportRoute.a);
      expect(_startsWithPdfHeader(result.pdfBytes), isTrue);
      expect(result.report.conservationError(), isNull);
      expect(seen['q1'], '数学 / 高数、线代 / 期中考试');
      expect(seen['q2'], '英语 / 作业本');
    });

    test('多学科/多文件夹整单信息区仍用“多学科”/“多文件夹”', () async {
      addCSourceRecords();
      final seen = <String, String>{};
      final svc = service(hasKey: true, seen: seen);
      // 整单级标签取调用方传入的“多学科”，不是首题的“数学”。
      expect(svc.subjectName, '多学科');
      expect(
        const PdfExportHeaderInfo(
          subjectName: '多学科',
          exportDateText: '2026-11-20',
        ).line,
        '错题本 · 多学科 · 2026-11-20',
      );
      final fileName = buildExportFileName(
        subjectName: '多学科',
        folderName: '多文件夹',
        date: DateTime(2026, 11, 20),
        version: ExportVersion.practice,
      );
      expect(fileName, contains('多学科'));
      expect(fileName, contains('多文件夹'));
      expect(fileName, isNot(contains('高数')));
      // 逐题来源行仍各印各的（与整单标签互不干扰）。
      await svc.generate(
        ids: const ['q1', 'q2'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
      );
      expect(seen['q1'], '数学 / 高数、线代 / 期中考试');
      expect(seen['q2'], '英语 / 作业本');
    });

    test('答案版：题目区来源行与练习版同一口径（题号一致）', () async {
      addCSourceRecords();
      final seen = <String, String>{};
      final result = await service(hasKey: false, seen: seen).generateVersions(
        ids: const ['q1', 'q2'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
        versions: const ExportVersionSelection.both(),
      );
      expect(result.allSucceeded, isTrue);
      final practice = result.practice!.result!;
      final answer = result.answer!.result!;
      expect(
        answer.questionPages.map((q) => q.displayNumber).toList(),
        practice.questionPages.map((q) => q.displayNumber).toList(),
      );
      expect(
        answer.questionPages.map((q) => q.questionId).toList(),
        practice.questionPages.map((q) => q.questionId).toList(),
      );
      // 答案版多答案区页数；两版题目区来源行来自同一份拼好的文本。
      expect(answer.totalPages, greaterThan(practice.totalPages));
      expect(seen['q1'], '数学 / 高数、线代 / 期中考试');
      expect(seen['q2'], '英语 / 作业本');
    });
  });
}

bool _startsWithPdfHeader(Uint8List bytes) =>
    bytes.length >= 5 &&
    bytes[0] == 0x25 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x44 &&
    bytes[3] == 0x46 &&
    bytes[4] == 0x2D;
