// Batch 11 第 6 项：错题本批量加入复习（拓展版）。
// 单元测试：批量加入 / 取消的计数与状态（joinReviewBatch /
// cancelReviewBatch，新规则：题不在 FSRS 池 → 入池建卡；已在池 →
// 跳过；无错因的题也可加；不播种错因记录），用 FakeRepo 覆盖
// setReviewJoinedFlag（内存翻标志）+ 真实内存调度器
//（InMemoryCardStore）做池，不碰真实数据库。
// Widget 测试：批量条三个按钮、勾选加入 + 跳过反馈、“全部加入”的
// 作用域（当前筛选结果，不限当前页）、“开始复习”跳转、批量取消。
// P3（2026-11-25，D6）：批量条“加入复习”“全部加入复习”改走 FSRS
// 入池（joinFsrsPool）：无错因的题也建卡（只建卡、不播种错因记录，
// 不计入失败）；已在池的题跳过并计数；文案为“新增 N 道；M 道已在复习，
// 跳过”。
// FSRS 全量迁移包2（2026-11-27）：hasJoinableCause 已删（8 个判定
// 测试随之删除，见下）；joinReviewBatch 改按池判定，单元测试重写。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/widgets/uikit.dart';

import 'wrongbook_page_test.dart'
    show FakeWrongbookRepo, boardRow, openBatchMenu, openMathList,
        openMathListCompact, pumpWrongbook, tapBatchMenuItem, wbq;

Question _bq(
  String id, {
  List<String> causes = const ['概念不清'],
  bool joined = false,
}) =>
    Question(
      id: id,
      title: '题 $id',
      subjectId: 'math',
      errorTypes: causes,
      createdAt: DateTime(2026, 11, 1),
      isOrganized: true,
      reviewJoined: joined,
      sliceKind: 'limit',
      sliceText: '题',
    );

CauseRecord _r(
  String qid, {
  String cause = '概念不清',
}) =>
    CauseRecord(
      questionId: qid,
      cause: cause,
      subjectId: 'math',
      joinedAt: DateTime(2026, 11, 1),
    );

/// 内存模拟的 setReviewJoinedFlag：只翻内存里的 reviewJoined 标志
///（FSRS 全量迁移包2：不再播种错因记录，无错因的题也可翻标志）。
/// 池判定走真实内存调度器（测试里传 FsrsReviewScheduler +
/// InMemoryCardStore），joinReviewBatch / cancelReviewBatch 本体不改写。
class _BatchFakeRepo extends QuestionRepository {
  _BatchFakeRepo() : super(AppDatabase.instance);

  List<Question> questions = [];
  List<CauseRecord> records = [];

  /// 十九批 A3：内存版已存查找（不碰真实库）。
  final List<SavedSearch> savedSearchList = [];

  @override
  Future<List<SavedSearch>> savedSearches() async =>
      List.of(savedSearchList);

  @override
  Future<void> saveSavedSearch(SavedSearch search) async {
    savedSearchList.removeWhere((s) => s.id == search.id);
    savedSearchList.add(search);
  }

  @override
  Future<void> deleteSavedSearch(String id) async {
    savedSearchList.removeWhere((s) => s.id == id);
  }

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

  @override
  Future<bool> setReviewJoinedFlag(Question q, bool joined) async {
    final i = questions.indexWhere((x) => x.id == q.id);
    if (i >= 0) questions[i] = questions[i].copyWith(reviewJoined: joined);
    return true;
  }
}

void main() {
  // 已删（FSRS 全量迁移包2）：'B11-6 hasJoinableCause：只加未解决错因的
  // 判定'组 8 个测试——'无错因 → 不可加'、'有错因、无记录 → 可加'、
  // '待解决记录 → 可加；解决中记录 → 可加'、'全部已解决、复查日未到 →
  // 不可加（跳过）'、'全部已解决、但到了复查时间 → 可加（仍要复查）'、
  // '混合：一个已解决、一个待解决 → 可加'、'混合：一个已解决、一个新错因
  // 尚无记录 → 可加'、'混合：全部已解决且复查日未到 → 不可加'。
  // 判定函数已删（批量加入改按 FSRS 池判定，不按错因治愈状态）。
  // 替代：下组 joinReviewBatch 新规则测试（按池加入/跳过）
  // 与新文件 test/fsrs_pkg2_migration_test.dart 的“重新加入”组。

  group('B11-6 joinReviewBatch / cancelReviewBatch：计数与库态（FSRS 全量迁移包2：按池判定）', () {
    test('加入 4 道、跳过 2 道；不播种，记录全不动', () async {
      final repo = _BatchFakeRepo();
      final scheduler = FsrsReviewScheduler(
        config: const SchedulerConfig(enableFuzzing: false),
        store: InMemoryCardStore(),
      );
      final q1 = _bq('q1'); // 不在池 → 加入
      final q2 = _bq('q2', causes: const ['方法不会']); // 已在池 → 跳过
      final q3 = _bq('q3', causes: const []); // 无错因、不在池 → 加入
      final q4 = _bq('q4', causes: const ['概念不清', '计算错误']); // 不在池 → 加入
      final q5 = _bq('q5', causes: const ['审题失误']); // 不在池 → 加入
      final q6 = _bq('q6', joined: true); // 已在池 → 跳过（不重复建卡）
      repo.questions = [q1, q2, q3, q4, q5, q6];
      repo.records = [
        _r('q2', cause: '方法不会'),
        _r('q4', cause: '概念不清'),
        _r('q5', cause: '审题失误'),
        _r('q6'),
      ];
      // FSRS 全量迁移包2：判定只看池——q2、q6 预先入池（治愈状态、
      // 复查日、有无错因都不再影响判定）。
      await scheduler.initializeQuestion('q2');
      await scheduler.initializeQuestion('q6');

      final result = await repo.joinReviewBatch(
        [q1, q2, q3, q4, q5, q6],
        scheduler: scheduler,
      );

      expect(result.joined, 4);
      expect(result.skipped, 2);
      expect(result.failed, 0);
      Question byId(String id) =>
          repo.questions.firstWhere((q) => q.id == id);
      expect(byId('q1').reviewJoined, isTrue);
      expect(byId('q2').reviewJoined, isFalse);
      expect(byId('q3').reviewJoined, isTrue);
      expect(byId('q4').reviewJoined, isTrue);
      expect(byId('q5').reviewJoined, isTrue);
      expect(byId('q6').reviewJoined, isTrue);
      // 不播种：记录数不变（4 条），已有记录全不动。
      expect(repo.records.length, 4);
      CauseRecord rec(String qid, String cause) => repo.records.firstWhere(
          (r) => r.questionId == qid && r.cause == cause);
      // FSRS 全量迁移包 7：CauseRecord 已无状态列；“记录全不动”
      // 改为断言冻结历史载体本身未被改写（错因名与补救历史不变）。
      final q4Solved = rec('q4', '概念不清');
      expect(q4Solved.cause, '概念不清');
      expect(q4Solved.remedyHistory, isEmpty);
      final q5Rec = rec('q5', '审题失误');
      expect(q5Rec.cause, '审题失误');
      expect(q5Rec.remedyHistory, isEmpty);
      expect(repo.records.where((r) => r.questionId == 'q3').length, 0);
      expect(repo.records.where((r) => r.questionId == 'q6').length, 1);
      // 池里现在 6 道全在。
      expect(await scheduler.pooledQuestionIds(),
          {'q1', 'q2', 'q3', 'q4', 'q5', 'q6'});
    });

    test('取消 1 道、跳过 1 道；记录保留', () async {
      final repo = _BatchFakeRepo();
      final q1 = _bq('q1', joined: true);
      final q2 = _bq('q2', joined: false);
      repo.questions = [q1, q2];
      repo.records = [_r('q1'), _r('q2')];

      final result = await repo.cancelReviewBatch([q1, q2]);

      expect(result.cancelled, 1);
      expect(result.skipped, 1);
      expect(result.failed, 0);
      expect(
          repo.questions.firstWhere((q) => q.id == 'q1').reviewJoined,
          isFalse);
      expect(
          repo.questions.firstWhere((q) => q.id == 'q2').reviewJoined,
          isFalse);
      // 记录保留：重加入可恢复。
      expect(repo.records.length, 2);
    });
  });

  group('B11-6 错题本批量条', () {
    _B116Repo reviewRepo() {
      final now = DateTime.now();
      return _B116Repo(
        questions: [
          wbq('qa', '待解决甲',
              folderIds: const ['f1'],
              errorTypes: const ['概念不清'],
              createdAt: now.subtract(const Duration(days: 1))),
          wbq('qb', '无错因题',
              folderIds: const ['f1'],
              errorTypes: const [],
              createdAt: now.subtract(const Duration(days: 2))),
          wbq('qc', '待解决乙',
              folderIds: const ['f1'],
              errorTypes: const ['方法不会'],
              createdAt: now.subtract(const Duration(days: 3))),
        ],
        folderList: const [
          Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
        ],
        records: [
          CauseRecord(
            questionId: 'qa',
            cause: '概念不清',
            subjectId: 'math',
            joinedAt: now,
          ),
        ],
        counts: const {'math': (0, 0, 0)},
      );
    }

    Future<void> openBatchBar(WidgetTester tester) async {
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      // 方案 A：单行工具条——已选文案 + 三个菜单 + 删除 + 退出。
      expect(find.text('已选 0 道'), findsOneWidget);
      expect(find.byKey(const Key('batch-select-menu')), findsOneWidget);
      expect(find.byKey(const Key('batch-organize-menu')), findsOneWidget);
      expect(find.byKey(const Key('batch-review-menu')), findsOneWidget);
      expect(find.text('批量删除'), findsOneWidget);
      expect(find.text('退出批量'), findsOneWidget);
    }

    /// P3：给 repo 与 pumpWrongbook 接同一个内存调度器（不碰真实数据库），
    /// 行内“已在复习”标记与入池结果共用同一池。
    FsrsReviewScheduler wireScheduler(_B116Repo repo) {
      final scheduler = FsrsReviewScheduler(
        config: const SchedulerConfig(enableFuzzing: false),
        store: InMemoryCardStore(),
      );
      repo.scheduler = scheduler;
      return scheduler;
    }

    testWidgets('未勾选时整理/批量删除禁用，复习菜单可点，选择与退出可用',
        (tester) async {
      final repo = reviewRepo();
      await pumpWrongbook(tester, repo: repo);
      await openMathListCompact(tester);
      await openBatchBar(tester);

      QmButton btn(String label) => tester.widget<QmButton>(
            find.ancestor(
              of: find.text(label),
              matching: find.byType(QmButton),
            ),
          );
      expect(btn('选择').onPressed, isNotNull);
      expect(btn('整理').onPressed, isNull);
      expect(btn('复习').onPressed, isNotNull);
      expect(btn('批量删除').onPressed, isNull);
      expect(btn('退出批量').onPressed, isNotNull);
      // 复习菜单 0 选时可打开：只有「全部加入复习」可用（它不需勾选，
      // 作用域是全部筛选结果），其余三项禁用。
      MenuItemButton item(String label) => tester.widget<MenuItemButton>(
            find.ancestor(
              of: find.text(label),
              matching: find.byType(MenuItemButton),
            ),
          );
      await openBatchMenu(tester, 'batch-review-menu');
      expect(item('加入复习').onPressed, isNull);
      expect(item('全部加入复习').onPressed, isNotNull);
      expect(item('立即专项练习').onPressed, isNull);
      expect(item('取消加入复习').onPressed, isNull);
    });

    testWidgets('勾选加入：3 道都建卡（无错因的题只建卡、不播种），给开始复习入口',
        (tester) async {
      final repo = reviewRepo();
      final scheduler = wireScheduler(repo);
      var goReviewCalls = 0;
      await pumpWrongbook(
        tester,
        repo: repo,
        scheduler: scheduler,
        onGoReview: ({String? subjectId}) => goReviewCalls++,
      );
      await openMathListCompact(tester);
      await openBatchBar(tester);
      // 全选：qa（待解决）+ qb（无错因）+ qc（待解决）。
      await tapBatchMenuItem(tester, 'batch-select-menu', '全选（整理、复习、删除）');
      expect(find.text('已选 3 道'), findsOneWidget);

      await tapBatchMenuItem(tester, 'batch-review-menu', '加入复习');
      await tester.pumpAndSettle();

      // P3：3 道都建卡（qb 无错因只建卡、不播种，不计入失败/跳过）。
      // FSRS 全量迁移包2：qb 无错因也可翻标志；不播种，记录只剩 qa 原记录。
      expect(find.text('新增 3 道'), findsOneWidget);
      expect(find.text('开始复习'), findsOneWidget);
      expect(await scheduler.pooledQuestionIds(), {'qa', 'qb', 'qc'});
      Question byId(String id) =>
          repo.questions.firstWhere((q) => q.id == id);
      expect(byId('qa').reviewJoined, isTrue);
      expect(byId('qc').reviewJoined, isTrue);
      expect(byId('qb').reviewJoined, isTrue);
      expect(repo.records.length, 1);
      expect(repo.records.where((r) => r.questionId == 'qb').length, 0);
      expect(repo.records.where((r) => r.questionId == 'qc').length, 0);

      await tester.tap(find.text('开始复习'));
      await tester.pumpAndSettle();
      expect(goReviewCalls, 1);
    });

    testWidgets('只勾无错因的题：只建卡、不播种错因记录，仍给开始复习入口',
        (tester) async {
      final repo = reviewRepo();
      final scheduler = wireScheduler(repo);
      await pumpWrongbook(tester, repo: repo, scheduler: scheduler);
      await openMathListCompact(tester);
      await openBatchBar(tester);
      // 方案 A：批量条不再有全选复选框；复选框顺序：qa 批量、qb 批量、
      // qc 批量……（按收集时间新→旧；每行只剩批量框，十七批 P2：
      // 导出方框已废）。qb 的批量框是第 1 个。
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 道'), findsOneWidget);

      await tapBatchMenuItem(tester, 'batch-review-menu', '加入复习');
      await tester.pumpAndSettle();

      // P3：qb 也建卡（added 1），播种失败不影响计数；仍给开始复习入口。
      expect(find.text('新增 1 道'), findsOneWidget);
      expect(find.text('开始复习'), findsOneWidget);
      expect(await scheduler.pooledQuestionIds(), {'qb'});
      // FSRS 全量迁移包2：无错因的题也可翻标志。
      expect(
          repo.questions.firstWhere((q) => q.id == 'qb').reviewJoined,
          isTrue);
      expect(repo.records.where((r) => r.questionId == 'qb').length, 0);
    });

    testWidgets('全选（仅复习） + 加入复习：作用域是当前筛选结果，不限当前页',
        (tester) async {
      final now = DateTime.now();
      final repo = _B116Repo(
        questions: [
          for (var i = 0; i < 12; i++)
            wbq('m$i', '数学题 $i',
                folderIds: const ['f1'],
                errorTypes: const ['概念不清'],
                createdAt: now.subtract(Duration(days: i + 1))),
        ],
        folderList: const [
          Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
        ],
        counts: const {'math': (0, 0, 0)},
      );
      await pumpWrongbook(tester, repo: repo, scheduler: wireScheduler(repo));
      await openMathList(tester);
      // 默认每页 10 道，只显示 10 张卡；不用勾选直接全部加入。
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      await tapBatchMenuItem(tester, 'batch-select-menu', '全选（仅复习）');
      await tapBatchMenuItem(tester, 'batch-review-menu', '加入复习');

      expect(find.text('新增 12 道'), findsOneWidget);
      expect(repo.questions.every((q) => q.reviewJoined), isTrue);
    });

    testWidgets('全选（仅复习） + 加入复习 + 错因筛选：只加筛出的错因的题',
        (tester) async {
      final repo = reviewRepo();
      final scheduler = wireScheduler(repo);
      await pumpWrongbook(tester, repo: repo, scheduler: scheduler);
      await openMathListCompact(tester);
      await tester.tap(find.text('筛选 ▾'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<String>).at(2));
      await tester.pumpAndSettle();
      await tester.tap(find.text('方法不会').last);
      await tester.pumpAndSettle();
      // 十九批 A1：行标题是 RichText，find.text 找不到。
      expect(boardRow('待解决乙'), findsOneWidget);
      expect(boardRow('待解决甲'), findsNothing);

      await openBatchBar(tester);
      await tapBatchMenuItem(tester, 'batch-select-menu', '全选（仅复习）');
      await tapBatchMenuItem(tester, 'batch-review-menu', '加入复习');

      expect(find.text('新增 1 道'), findsOneWidget);
      expect(await scheduler.pooledQuestionIds(), {'qc'});
      Question byId(String id) =>
          repo.questions.firstWhere((q) => q.id == id);
      expect(byId('qc').reviewJoined, isTrue);
      expect(byId('qa').reviewJoined, isFalse);
    });

    testWidgets('批量取消：取消 1 道、跳过 1 道，记录保留',
        (tester) async {
      final now = DateTime.now();
      final repo = _B116Repo(
        questions: [
          wbq('qa', '待解决甲',
                  folderIds: const ['f1'],
                  errorTypes: const ['概念不清'],
                  createdAt: now.subtract(const Duration(days: 1)))
              .copyWith(reviewJoined: true),
          wbq('qb', '待解决乙',
              folderIds: const ['f1'],
              errorTypes: const ['方法不会'],
              createdAt: now.subtract(const Duration(days: 2))),
        ],
        folderList: const [
          Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
        ],
        records: [
          CauseRecord(
            questionId: 'qa',
            cause: '概念不清',
            subjectId: 'math',
            joinedAt: now,
          ),
          CauseRecord(
            questionId: 'qb',
            cause: '方法不会',
            subjectId: 'math',
            joinedAt: now,
          ),
        ],
        counts: const {'math': (0, 0, 0)},
      );
      await pumpWrongbook(tester, repo: repo);
      await openMathListCompact(tester);
      await openBatchBar(tester);
      await tapBatchMenuItem(tester, 'batch-select-menu', '全选（整理、复习、删除）');

      await tapBatchMenuItem(tester, 'batch-review-menu', '取消加入复习');
      await tester.pumpAndSettle();

      expect(find.text('已取消加入复习 1 道；1 道未加入复习，跳过'),
          findsOneWidget);
      expect(
          repo.questions
              .firstWhere((q) => q.id == 'qa')
              .reviewJoined,
          isFalse);
      // 记录保留：重加入可恢复。
      expect(
          repo.records
              .where((r) => r.questionId == 'qa' && r.cause == '概念不清')
              .length,
          1);
    });
  });
}

/// 错题本 widget 测试用的 FakeRepo 子类：只覆盖 setReviewJoinedFlag
///（内存翻标志；FSRS 全量迁移包2：不再播种错因记录，无错因的题也可加）。
/// 批量判定与计数走真实的 QuestionRepository.joinReviewBatch /
/// cancelReviewBatch（池走内存调度器）。
class _B116Repo extends FakeWrongbookRepo {
  _B116Repo({
    required super.questions,
    required super.folderList,
    super.records = const [],
    super.counts = const {},
  });

  @override
  Future<bool> setReviewJoinedFlag(Question q, bool joined) async {
    final i = questions.indexWhere((x) => x.id == q.id);
    if (i >= 0) questions[i] = questions[i].copyWith(reviewJoined: joined);
    return true;
  }
}
