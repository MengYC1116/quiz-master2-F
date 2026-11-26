// FSRS 口径迁移（方案 §2.3，Meng 2026-11-25 定）：报告分布不再是
// “范围内未掌握题数”，而是“范围内有正式作答的题数”（attempts 口径，
// 按题去重；专项练习不计；见 lib/data/report_stats.dart 的
// computeReportStats.answeredBySubject）。因此分布数与错题本封面数
// 按定义不再相等——封面是另一口径的数，本文件不再断言两者相等，只断言
// 报告分布行本身符合新定义。
// 仍沿用 SR3-2 的两组陈旧记录夹具，证明分布不再受错因记录状态影响：
// （1）某题错因 [计算错误] 已治愈 → 取消加入复习（记录保留）
//     → 详情页加错因 `概念不清`（无记录）。旧口径下报告判未掌握，
//     分布 1 道；新口径只看 attempts：该题有正式作答即计 1 道。
// （2）某题 [计算错误 已解决，概念不清 待解决] → 取消加入复习
//     → 详情页删掉 `概念不清`（待解决记录残留）。新口径下同一题
//     两次正式作答 + 一次专项练习作答仍只计 1 道（按题去重、只计正式）。
// 只用 FakeRepo，不碰真实数据库；不用异步文件 IO。期望值由
// computeReportStats 直接算出，不手写。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/report_stats.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/report/report_page.dart';
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

/// 同时服务报告页的 FakeRepo（只覆盖读方法，不碰真实数据库）。
class _StaleRepo extends QuestionRepository {
  _StaleRepo({
    required this.questions,
    required this.records,
    this.attempts = const [],
  }) : super(AppDatabase.instance);

  List<Question> questions;
  List<CauseRecord> records;
  List<AttemptData> attempts;

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

  // 十九批 C：内存版已存查找（A3 起 load() 读 savedSearches；不覆写
  // 会走真实库、页面卡 loading、pumpAndSettle 超时，见 D-225）。
  @override
  Future<List<SavedSearch>> savedSearches() async => const [];

  // P3：报告 load() 读全部 attempts（同款 D-225：不覆写会走真实库、
  // 页面卡 loading）。
  @override
  Future<List<AttemptData>> loadAllAttempts() async => List.of(attempts);

  @override
  Future<Set<String>> fsrsPoolQuestionIds() async => const {};
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

/// 一条作答夹具：默认正式复习（mode = 到期复习），今天作答。
AttemptData _attempt(
  String questionId, {
  String mode = ReviewMode.due,
  int? correct,
  List<String> causeIds = const [],
  String session = 's1',
}) => AttemptData(
  id: 'att-$questionId-$mode-$correct-$session',
  questionId: questionId,
  sessionId: session,
  mode: mode,
  correct: correct,
  answerVersion: 1,
  contentVersion: 0,
  status: '已提交',
  causeIds: causeIds,
  submissionId: 'sub-$questionId-$mode-$correct-$session',
  createdAt: _today.millisecondsSinceEpoch,
);

/// 报告默认范围“本周”的起点（与 ReportState.rangeStart 同口径：
/// 本周一 00:00）。
DateTime get _weekStart {
  final t = _today;
  return t.subtract(Duration(days: t.weekday - 1));
}

/// 新口径分布行期望值：直接由 computeReportStats 算出（与页面同一函数），
/// 不手写数字。
String _expectedDistRow({
  required List<AttemptData> attempts,
  required List<Question> questions,
}) {
  final stats = computeReportStats(
    attempts: attempts,
    questions: questions,
    knowledgePoints: const [],
    subjectIdsInOrder: const ['math'],
    rangeStart: _weekStart,
  );
  return '数学 · 作答 ${stats.answeredBySubject['math'] ?? 0} 道';
}

void main() {
  group('FSRS 口径：报告分布 = 范围内正式作答题数（attempts 口径）', () {
    testWidgets('路径 1：陈旧已治愈记录在、新错因无记录——分布只看 attempts，该题有正式作答即计 1 道',
        (tester) async {
      final questions = [_q('q1', ['概念不清'])];
      final attempts = [_attempt('q1', correct: 1)];
      final repo = _StaleRepo(
        questions: questions,
        records: [_r('q1', '计算错误', CauseStatus.solved)],
        attempts: attempts,
      );
      await _pumpReport(tester, repo);
      expect(find.text('各科正式作答（只按学科看）'), findsOneWidget);
      expect(
        find.text(_expectedDistRow(attempts: attempts, questions: questions)),
        findsOneWidget,
      );
      // 旧文案已无：分布行不再是“X 道错题”。
      expect(find.textContaining('道错题'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('路径 2：已删错因的待解决记录残留——同一题两次正式作答 + 一次专项练习仍只计 1 道',
        (tester) async {
      final questions = [_q('q1', ['计算错误'])];
      final attempts = [
        _attempt('q1', correct: 0, causeIds: ['概念不清'], session: 's1'),
        _attempt('q1', correct: 0, causeIds: ['概念不清'], session: 's2'),
        _attempt('q1', mode: ReviewMode.practice, correct: 0, session: 's3'),
      ];
      final repo = _StaleRepo(
        questions: questions,
        records: [
          _r('q1', '计算错误', CauseStatus.solved),
          _r('q1', '概念不清', CauseStatus.pending),
        ],
        attempts: attempts,
      );
      await _pumpReport(tester, repo);
      expect(find.text('各科正式作答（只按学科看）'), findsOneWidget);
      expect(
        find.text(_expectedDistRow(attempts: attempts, questions: questions)),
        findsOneWidget,
      );
      expect(find.textContaining('道错题'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
