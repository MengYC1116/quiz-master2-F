// Batch 7 P1（SR3-2）：报告分布数与错题本封面数在陈旧记录下一致。
// 报告 `_isMastered` 已改用与错题本/首页同一的记录口径
// （`QuestionRepository.reviewBucketOf(records) == ReviewBucket.solved`），
// 不再按 `allCauses` 逐因查记录。覆盖自审里的两条复现路径：
// （1）报告多算：某题错因 [计算错误] 已治愈 → 取消加入复习（记录保留）
//     → 详情页加错因 `概念不清`（无记录）。旧口径下报告判未掌握、
//     错题本判已掌握，分布数 = 封面数 + 1；修后两边都判已掌握，
//     分布 0 道、封面 0 道。
// （2）报告少算：某题 [计算错误 已解决，概念不清 待解决] → 取消加入复习
//     → 详情页删掉 `概念不清`（待解决记录残留）。旧口径下报告只看剩下
//     的 `计算错误` 判已掌握、错题本判未掌握，分布数 = 封面数 − 1；
//     修后两边都判未掌握，分布 1 道、封面 1 道。
// 用同一份 FakeRepo 同时泵报告页（分布行）与错题本页（封面“道题”数），
// 两边数字必须相等。只用 FakeRepo，不碰真实数据库；不用异步文件 IO。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/report/report_page.dart';
import 'package:quiz_master2/modules/wrongbook/wrongbook_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';

DateTime get _today {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

Question _q(String id, List<String> causes) => Question(
      id: id,
      title: '题 $id',
      subjectId: 'math',
      errorTypes: causes,
      createdAt: _today,
      isOrganized: true,
      isArchived: false,
      reviewJoined: true,
      sliceKind: 'material',
      sliceText: '题：$id',
    );

CauseRecord _r(String qid, String cause, CauseStatus status) => CauseRecord(
      questionId: qid,
      cause: cause,
      subjectId: 'math',
      status: status,
      solvedCount: status == CauseStatus.solved ? 2 : 0,
      lastCheck: _today,
      joinedAt: _today,
    );

/// 同时服务报告页与错题本页的 FakeRepo（只覆盖读方法，不碰真实数据库）。
class _StaleRepo extends QuestionRepository {
  _StaleRepo({required this.questions, required this.records})
      : super(AppDatabase.instance);

  List<Question> questions;
  List<CauseRecord> records;

  @override
  Future<List<Subject>> subjects() async => [Subject.math];

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      questions.where((q) => includeArchived || !q.isArchived).toList();

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  @override
  Future<AppSettings> settings() async => AppSettings.defaults;

  @override
  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
          String questionId) async =>
      const [];

  @override
  Future<List<Folder>> folders({String? subjectId}) async => const [];

  @override
  Future<List<Exam>> exams() async => const [];

  @override
  Future<List<String>> tags() async => const [];

  @override
  Future<Map<String, (int, int, int)>> subjectCounts(
          {bool includeArchived = false}) async =>
      const {};
}

Future<void> _pumpReport(WidgetTester tester, _StaleRepo repo) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: 1.0),
      home: Scaffold(
        body: ReportPage(
          repo: repo,
          onGoReview: () {},
          onOpenWrongbookFiltered: ({
            String? subjectId,
            String? cause,
            String? knowledgePointId,
          }) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpWrongbook(WidgetTester tester, _StaleRepo repo) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: 1.0),
      home: Scaffold(
        body: WrongbookPage(
          repo: repo,
          onOpenHome: () {},
          onOpenDetail: (_, __) async {},
          onGoReview: ({String? subjectId}) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 书架封面“道题”数：`_bookStat('道题', total)` 的数字与“道题”文案
/// 是同一 Column 里的两个 Text（数字在上、文案在下）。
String _coverTotal(WidgetTester tester) {
  final column = find.byWidgetPredicate((w) {
    if (w is! Column) return false;
    final texts = w.children.whereType<Text>().toList();
    return texts.length == 2 && texts[1].data == '道题';
  });
  expect(column, findsOneWidget);
  final texts =
      tester.widget<Column>(column).children.whereType<Text>().toList();
  return texts.first.data!;
}

void main() {
  group('SR3-2 陈旧记录：报告分布数 = 错题本封面数', () {
    testWidgets('路径 1（旧口径报告多算）：新错因无记录，已治愈的陈旧记录在——两边都判已掌握，分布 0 道、封面 0 道',
        (tester) async {
      final repo = _StaleRepo(
        questions: [_q('q1', ['概念不清'])],
        records: [_r('q1', '计算错误', CauseStatus.solved)],
      );
      await _pumpReport(tester, repo);
      expect(find.text('数学 · 0 道错题'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await _pumpWrongbook(tester, repo);
      expect(_coverTotal(tester), '0');
      expect(tester.takeException(), isNull);
    });

    testWidgets('路径 2（旧口径报告少算）：已删错因的待解决记录残留——两边都判未掌握，分布 1 道、封面 1 道',
        (tester) async {
      final repo = _StaleRepo(
        questions: [_q('q1', ['计算错误'])],
        records: [
          _r('q1', '计算错误', CauseStatus.solved),
          _r('q1', '概念不清', CauseStatus.pending),
        ],
      );
      await _pumpReport(tester, repo);
      expect(find.text('数学 · 1 道错题'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await _pumpWrongbook(tester, repo);
      expect(_coverTotal(tester), '1');
      expect(tester.takeException(), isNull);
    });
  });
}
