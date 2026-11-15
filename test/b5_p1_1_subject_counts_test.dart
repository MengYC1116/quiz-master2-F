// SR-P1-1 回归：错题本封面三数与首页焦点卡同一互斥拆分口径。
//
// 旧口径两处不一致：
// (a) subjectCounts 的要复习只算 `status != solved`，纯复查题（全部错因
//     已解决、但有一条到了复查时间）封面要复习为 0、待复查为 1，
//     而首页 dueToday 把它算进“要复习”；
// (b) subjectCounts 两个 if 独立计数，一道题可同时计入要复习与待复查，
//     而首页焦点卡是互斥拆分（有未解决错因计待解决，只有复查到期才计
//     复查，两者之和 = 要复习总数）。
// 修后三处共用 QuestionRepository.reviewBucketOf：
// 纯复查题只计待复查、未解决错因题只计要复习、两者之和等于总数。
// 只用 FakeRepo（覆盖 all / causeRecords / subjects），不碰真实数据库。
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';

import 'home_page_test.dart' show FakeRepo, pumpHome;

class _CountsFakeRepo extends QuestionRepository {
  _CountsFakeRepo() : super(AppDatabase.instance);

  List<Question> questions = [];
  List<CauseRecord> records = [];
  List<Subject> subjectsValue = Subject.all;

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      questions
          .where((q) => includeArchived || !q.isArchived)
          .toList();

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

  @override
  Future<List<Subject>> subjects() async => List.of(subjectsValue);
}

Question _q(String id,
        {String subjectId = 'math',
        bool joined = true,
        bool organized = true}) =>
    Question(
      id: id,
      title: '题 $id',
      subjectId: subjectId,
      errorTypes: const ['概念不清'],
      createdAt: DateTime(2026, 11, 1),
      isOrganized: organized,
      reviewJoined: joined,
      sliceKind: 'limit',
      sliceText: '题',
    );

CauseRecord _r(String qid,
        {String cause = '概念不清',
        String subjectId = 'math',
        CauseStatus status = CauseStatus.pending,
        DateTime? recheckDate}) =>
    CauseRecord(
      questionId: qid,
      cause: cause,
      subjectId: subjectId,
      status: status,
      solvedCount: status == CauseStatus.solved ? 2 : 0,
      recheckDate: recheckDate,
      joinedAt: DateTime(2026, 11, 1),
    );

/// 共享场景（数学 7 题 + 英语 1 题）：
/// - q1：一个待解决错因 → 只计要复习；
/// - q2：全部已解决、一条到复查时间 → 只计待复查；
/// - q3：一个待解决 + 一个已解决且到复查时间 → 只计要复习（旧口径双计）；
/// - q4：全部已解决、复查日未到 → 只计已解决；
/// - q5：无错因记录 → 三处都不计；
/// - q6：待解决但未整理、q7：待解决但未加入复习 → 都不计；
/// - q8（英语）：全部已解决、一条到复查时间 → 只计待复查。
({List<Question> questions, List<CauseRecord> records}) _scenario() {
  final yesterday = DateTime.now().subtract(const Duration(days: 1));
  final nextWeek = DateTime.now().add(const Duration(days: 7));
  final questions = [
    _q('q1'),
    _q('q2'),
    _q('q3'),
    _q('q4'),
    _q('q5'),
    _q('q6', organized: false),
    _q('q7', joined: false),
    _q('q8', subjectId: 'english'),
  ];
  final records = [
    _r('q1'),
    _r('q2', status: CauseStatus.solved, recheckDate: yesterday),
    _r('q3', cause: '审题失误'),
    _r('q3', status: CauseStatus.solved, recheckDate: yesterday),
    _r('q4', status: CauseStatus.solved, recheckDate: nextWeek),
    _r('q6'),
    _r('q7'),
    _r('q8',
        subjectId: 'english',
        status: CauseStatus.solved,
        recheckDate: yesterday),
  ];
  return (questions: questions, records: records);
}

void main() {
  group('SR-P1-1 封面三数与首页口径一致（互斥拆分）', () {
    test('reviewBucketOf：四桶互斥，混合错因题只落待解决', () {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final nextWeek = DateTime.now().add(const Duration(days: 7));
      // SR2-64：复查日恰好是今天——零点与当前时刻各一，都算到期。
      // isRecheckDue 按日期比较（!d.isAfter(today)），当天任意时刻
      // 都落 recheck 桶、isReviewDue 为真；这是“待复查”与“已解决”
      // 的分界点。
      final now = DateTime.now();
      final todayMidnight = DateTime(now.year, now.month, now.day);
      expect(
          QuestionRepository.reviewBucketOf([
            _r('x', status: CauseStatus.solved, recheckDate: todayMidnight),
          ]),
          ReviewBucket.recheck);
      expect(
          QuestionRepository.reviewBucketOf([
            _r('x', status: CauseStatus.solved, recheckDate: now),
          ]),
          ReviewBucket.recheck);
      expect(
          QuestionRepository.isReviewDue([
            _r('x', status: CauseStatus.solved, recheckDate: todayMidnight),
          ]),
          isTrue);
      expect(
          QuestionRepository.isReviewDue([
            _r('x', status: CauseStatus.solved, recheckDate: now),
          ]),
          isTrue);
      expect(QuestionRepository.reviewBucketOf([]), ReviewBucket.none);
      expect(
          QuestionRepository.reviewBucketOf([_r('x')]), ReviewBucket.pending);
      expect(
          QuestionRepository.reviewBucketOf([
            _r('x', status: CauseStatus.solved, recheckDate: yesterday),
            _r('x', cause: '审题失误'),
          ]),
          ReviewBucket.pending);
      expect(
          QuestionRepository.reviewBucketOf([
            _r('x', status: CauseStatus.solved, recheckDate: yesterday),
          ]),
          ReviewBucket.recheck);
      expect(
          QuestionRepository.reviewBucketOf([
            _r('x', status: CauseStatus.solved, recheckDate: nextWeek),
          ]),
          ReviewBucket.solved);
      expect(QuestionRepository.isReviewDue([_r('x')]), isTrue);
      expect(
          QuestionRepository.isReviewDue([
            _r('x', status: CauseStatus.solved, recheckDate: yesterday),
          ]),
          isTrue);
      expect(
          QuestionRepository.isReviewDue([
            _r('x', status: CauseStatus.solved, recheckDate: nextWeek),
          ]),
          isFalse);
      expect(QuestionRepository.isReviewDue([]), isFalse);
    });

    test('subjectCounts：纯复查题只计待复查，混合题只计要复习，不双计',
        () async {
      final s = _scenario();
      final repo = _CountsFakeRepo()
        ..questions = s.questions
        ..records = s.records;
      final counts = await repo.subjectCounts();
      // 数学：要复习 q1、q3；待复查 q2；已解决 q4；q5/q6/q7 不计。
      expect(counts['math'], (2, 1, 1));
      // 英语：待复查 q8。
      expect(counts['english'], (0, 1, 0));
      expect(counts['politics'], (0, 0, 0));
    });

    test('封面两数之和 = 首页要复习总数（同科）', () async {
      final s = _scenario();
      final repo = _CountsFakeRepo()
        ..questions = s.questions
        ..records = s.records;
      final counts = await repo.subjectCounts();
      final rev = await repo.homeRevCounts();
      for (final subjectId in ['math', 'english', 'politics']) {
        final c = counts[subjectId]!;
        expect(c.$1 + c.$2, rev[subjectId],
            reason: '$subjectId：要复习 + 待复查 应等于首页该科要复习数');
      }
      expect(rev['math'], 3);
      expect(rev['english'], 1);
      expect(rev['politics'], 0);
      // dueToday 的题正是要复习 + 待复查那 4 道。
      expect(
          (await repo.dueToday()).map((q) => q.id).toSet(),
          {'q1', 'q2', 'q3', 'q8'});
    });

    testWidgets('首页焦点卡拆分与封面三数一致：待解决 2 道 · 复查 2 道',
        (tester) async {
      final s = _scenario();
      final repo = FakeRepo()
        ..due = s.questions
            .where((q) => {'q1', 'q2', 'q3', 'q8'}.contains(q.id))
            .toList()
        ..records = s.records
        ..rev = {'math': 3, 'english': 1, 'politics': 0};
      await pumpHome(tester, repo: repo);
      // 焦点卡总数 4 = 封面数学（2 + 1）+ 英语（0 + 1）。
      expect(find.text('4 道要复习'), findsOneWidget);
      expect(find.text('待解决 2 道 · 复查 2 道'), findsOneWidget);
    });

    testWidgets('真实仓储泵首页：焦点卡待解决 2 道 · 复查 2 道（SR2-61）',
        (tester) async {
      // 真实 QuestionRepository + 内存库，不用手填的 FakeRepo：
      // 钉住“仓储 → 首页焦点卡”这一段接线。openForTest 只建表不播种，
      // 学科/题/错因记录都用仓库写方法播种（与仓储层单测同款做法）。
      // sqflite_ffi 走 isolate：testWidgets 的 FakeAsync 下直接 await
      // 播种永不完成（实测 10 分钟超时），播种与仓储层断言必须包在
      // tester.runAsync 里（真实异步区）；泵首页本身仍走 tester。
      // SR3-20：tearDown 注册在播种之前——播种抛错时测试库单例也不残留。
      addTearDown(() async => AppDatabase.resetForTest());
      await tester.runAsync(() async {
        final db = await AppDatabase.openForTest();
        AppDatabase.useDatabaseForTest(db);
        final repo = QuestionRepository(AppDatabase.instance);
        for (final s in Subject.all) {
          await repo.saveSubject(s);
        }
        final s = _scenario();
        for (final q in s.questions) {
          await repo.save(q);
        }
        for (final r in s.records) {
          await repo.saveCauseRecord(r);
        }
        // 先断言仓储层算出的数与 FakeRepo 手填数一致，再泵首页：
        // 若文案不对，能分清是仓储算错还是首页渲染错。
        expect((await repo.dueToday()).map((q) => q.id).toSet(),
            {'q1', 'q2', 'q3', 'q8'});
        expect(await repo.homeRevCounts(),
            {'math': 3, 'english': 1, 'politics': 0});
      });
      final repo = QuestionRepository(AppDatabase.instance);
      // 真实仓储的 Future.wait 在 FakeAsync 下不完成：_load 挂起、
      // 加载圈一直转，pumpAndSettle 会超时。改用真实时间驱动：
      // 每轮先在真实异步区等 100ms（让 sqflite isolate 回包到达），
      // 再 pump 一帧，直到焦点卡文案出现；30 轮（3 秒）没等到就
      // 明确失败，不静默挂起。
      await pumpHome(tester, repo: repo, settle: false);
      var found = false;
      for (var i = 0; i < 30 && !found; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
        found = find.text('4 道要复习').evaluate().isNotEmpty;
      }
      expect(found, isTrue, reason: '真实仓储加载后焦点卡应显示 4 道要复习');
      // 焦点卡总数 4 = 封面数学（2 + 1）+ 英语（0 + 1），与手填
      // FakeRepo 的用例同一文案，但数是真实仓储算出来的。
      expect(find.text('待解决 2 道 · 复查 2 道'), findsOneWidget);
      // SR3-20：补断言分科行文案（与 FakeRepo 的“下方 4 格”用例同款）：
      // 数学要复习 3 道（q1/q2/q3）· 待整理 1 道（q6 未整理）；
      // 英语要复习 1 道（q8）· 待整理 0 道；政治 0 道 · 待整理 0 道。
      expect(find.text('要复习 3 道 · 待整理 1 道'), findsOneWidget);
      expect(find.text('要复习 1 道 · 待整理 0 道'), findsOneWidget);
      expect(find.text('要复习 0 道 · 待整理 0 道'), findsOneWidget);
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
