// Batch 11 第 6 项：错题本批量加入复习（拓展版）。
// 单元测试：只加未解决错因的判定（hasJoinableCause）+ 批量加入 /
// 取消的计数与状态（joinReviewBatch / cancelReviewBatch），用 FakeRepo
// 覆盖 causeRecords / setReviewJoined（与真实
// AppDatabase.setReviewJoinedInto 同语义的内存模拟），不碰真实数据库。
// Widget 测试：批量条三个按钮、勾选加入 + 跳过反馈、“全部加入”的
// 作用域（当前筛选结果，不限当前页）、“开始复习”跳转、批量取消。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/widgets/uikit.dart';

import 'wrongbook_page_test.dart'
    show FakeWrongbookRepo, openMathList, openMathListCompact, pumpWrongbook, wbq;

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
  CauseStatus status = CauseStatus.pending,
  int solvedCount = 0,
  DateTime? recheckDate,
}) =>
    CauseRecord(
      questionId: qid,
      cause: cause,
      subjectId: 'math',
      status: status,
      solvedCount: solvedCount,
      recheckDate: recheckDate,
      joinedAt: DateTime(2026, 11, 1),
    );

/// 内存模拟的 setReviewJoined：与真实
/// AppDatabase.setReviewJoinedInto 同语义——无错因加不进（false）；
/// 加入时给尚无记录的错因补一条待解决记录，已有记录不动；
/// 取消只翻标志，记录保留。
class _BatchFakeRepo extends QuestionRepository {
  _BatchFakeRepo() : super(AppDatabase.instance);

  List<Question> questions = [];
  List<CauseRecord> records = [];

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

  @override
  Future<bool> setReviewJoined(Question q, bool joined) async {
    if (joined && q.allCauses.isEmpty) return false;
    final i = questions.indexWhere((x) => x.id == q.id);
    if (i >= 0) questions[i] = questions[i].copyWith(reviewJoined: joined);
    if (joined) {
      for (final c in q.allCauses) {
        if (!records.any((r) => r.questionId == q.id && r.cause == c)) {
          records.add(
            CauseRecord(
              questionId: q.id,
              cause: c,
              subjectId: q.subjectId,
              joinedAt: DateTime(2026, 11, 1),
            ),
          );
        }
      }
    }
    return true;
  }
}

void main() {
  group('B11-6 hasJoinableCause：只加未解决错因的判定', () {
    final future = DateTime.now().add(const Duration(days: 7));
    final past = DateTime.now().subtract(const Duration(days: 1));

    test('无错因 → 不可加', () {
      expect(QuestionRepository.hasJoinableCause(_bq('x', causes: []), []),
          isFalse);
    });
    test('有错因、无记录 → 可加', () {
      expect(
          QuestionRepository.hasJoinableCause(_bq('x'), []), isTrue);
    });
    test('待解决记录 → 可加；解决中记录 → 可加', () {
      expect(
          QuestionRepository.hasJoinableCause(
              _bq('x'), [_r('x', status: CauseStatus.pending)]),
          isTrue);
      expect(
          QuestionRepository.hasJoinableCause(
              _bq('x'), [_r('x', status: CauseStatus.inProgress)]),
          isTrue);
    });
    test('全部已解决、复查日未到 → 不可加（跳过）', () {
      expect(
          QuestionRepository.hasJoinableCause(_bq('x'), [
            _r('x', status: CauseStatus.solved, solvedCount: 2,
                recheckDate: future),
          ]),
          isFalse);
    });
    test('全部已解决、但到了复查时间 → 可加（仍要复查）', () {
      expect(
          QuestionRepository.hasJoinableCause(_bq('x'), [
            _r('x', status: CauseStatus.solved, solvedCount: 2,
                recheckDate: past),
          ]),
          isTrue);
    });
    test('混合：一个已解决、一个待解决 → 可加', () {
      expect(
          QuestionRepository.hasJoinableCause(_bq('x', causes: [
            '概念不清',
            '计算错误',
          ]), [
            _r('x', cause: '概念不清', status: CauseStatus.solved,
                solvedCount: 2, recheckDate: future),
            _r('x', cause: '计算错误', status: CauseStatus.pending),
          ]),
          isTrue);
    });
    test('混合：一个已解决、一个新错因尚无记录 → 可加', () {
      expect(
          QuestionRepository.hasJoinableCause(_bq('x', causes: [
            '概念不清',
            '计算错误',
          ]), [
            _r('x', cause: '概念不清', status: CauseStatus.solved,
                solvedCount: 2, recheckDate: future),
          ]),
          isTrue);
    });
    test('混合：全部已解决且复查日未到 → 不可加', () {
      expect(
          QuestionRepository.hasJoinableCause(_bq('x', causes: [
            '概念不清',
            '计算错误',
          ]), [
            _r('x', cause: '概念不清', status: CauseStatus.solved,
                solvedCount: 2, recheckDate: future),
            _r('x', cause: '计算错误', status: CauseStatus.solved,
                solvedCount: 2, recheckDate: future),
          ]),
          isFalse);
    });
  });

  group('B11-6 joinReviewBatch / cancelReviewBatch：计数与库态', () {
    test('加入 4 道、跳过 2 道；已治愈错因的记录不动，只补未解决的', () async {
      final repo = _BatchFakeRepo();
      final future = DateTime.now().add(const Duration(days: 7));
      final past = DateTime.now().subtract(const Duration(days: 1));
      final q1 = _bq('q1'); // 无记录 → 加入
      final q2 = _bq('q2', causes: const ['方法不会']); // 已解决、复查未到 → 跳过
      final q3 = _bq('q3', causes: const []); // 无错因 → 跳过
      final q4 = _bq('q4', causes: const ['概念不清', '计算错误']); // 一已解决一无记录 → 加入
      final q5 = _bq('q5', causes: const ['审题失误']); // 已解决但到复查时间 → 加入
      final q6 = _bq('q6', joined: true); // 已加入、待解决记录 → 重加入也计入
      repo.questions = [q1, q2, q3, q4, q5, q6];
      repo.records = [
        _r('q2', cause: '方法不会', status: CauseStatus.solved,
            solvedCount: 2, recheckDate: future),
        _r('q4', cause: '概念不清', status: CauseStatus.solved,
            solvedCount: 2, recheckDate: future),
        _r('q5', cause: '审题失误', status: CauseStatus.solved,
            solvedCount: 2, recheckDate: past),
        _r('q6', status: CauseStatus.pending),
      ];

      final result = await repo.joinReviewBatch([q1, q2, q3, q4, q5, q6]);

      expect(result.joined, 4);
      expect(result.skipped, 2);
      expect(result.failed, 0);
      Question byId(String id) =>
          repo.questions.firstWhere((q) => q.id == id);
      expect(byId('q1').reviewJoined, isTrue);
      expect(byId('q2').reviewJoined, isFalse);
      expect(byId('q3').reviewJoined, isFalse);
      expect(byId('q4').reviewJoined, isTrue);
      expect(byId('q5').reviewJoined, isTrue);
      expect(byId('q6').reviewJoined, isTrue);
      // q1、q4 的新错因各补一条待解决记录；q4 已治愈的错因记录不动。
      CauseRecord rec(String qid, String cause) => repo.records.firstWhere(
          (r) => r.questionId == qid && r.cause == cause);
      expect(rec('q1', '概念不清').status, CauseStatus.pending);
      final q4Solved = rec('q4', '概念不清');
      expect(q4Solved.status, CauseStatus.solved);
      expect(q4Solved.solvedCount, 2);
      expect(q4Solved.recheckDate, future);
      expect(rec('q4', '计算错误').status, CauseStatus.pending);
      // q5 复查到期的已解决记录不动（不重置计数、不清复查日）。
      final q5Rec = rec('q5', '审题失误');
      expect(q5Rec.status, CauseStatus.solved);
      expect(q5Rec.solvedCount, 2);
      expect(q5Rec.recheckDate, past);
      // q2、q3 没有新增记录。
      expect(repo.records.where((r) => r.questionId == 'q2').length, 1);
      expect(repo.records.where((r) => r.questionId == 'q3').length, 0);
      // q6 已有的待解决记录还是原来那一条，不重复建。
      expect(repo.records.where((r) => r.questionId == 'q6').length, 1);
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
            status: CauseStatus.pending,
            joinedAt: now,
          ),
        ],
        counts: const {'math': (0, 0, 0)},
      );
    }

    Future<void> openBatchBar(WidgetTester tester) async {
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      expect(find.text('加入复习'), findsOneWidget);
      expect(find.text('全部加入复习'), findsOneWidget);
      expect(find.text('取消加入复习'), findsOneWidget);
    }

    testWidgets('未勾选时加入/取消禁用，全部加入可用',
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
      expect(btn('加入复习').onPressed, isNull);
      expect(btn('取消加入复习').onPressed, isNull);
      expect(btn('全部加入复习').onPressed, isNotNull);
    });

    testWidgets('勾选加入：加入 2 道、跳过 1 道，给开始复习入口',
        (tester) async {
      final repo = reviewRepo();
      var goReviewCalls = 0;
      await pumpWrongbook(
        tester,
        repo: repo,
        onGoReview: ({String? subjectId}) => goReviewCalls++,
      );
      await openMathListCompact(tester);
      await openBatchBar(tester);
      // 全选：qa（待解决）+ qb（无错因）+ qc（待解决）。
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('已选 3 道'), findsOneWidget);

      await tester.tap(find.text('加入复习'));
      await tester.pumpAndSettle();

      expect(find.text('已加入复习 2 道；1 道已无未解决错因，跳过'),
          findsOneWidget);
      expect(find.text('开始复习'), findsOneWidget);
      Question byId(String id) =>
          repo.questions.firstWhere((q) => q.id == id);
      expect(byId('qa').reviewJoined, isTrue);
      expect(byId('qc').reviewJoined, isTrue);
      expect(byId('qb').reviewJoined, isFalse);
      // qc 新补一条待解决记录；qa 原记录不动；qb 无记录。
      expect(
          repo.records
              .where((r) => r.questionId == 'qc' && r.cause == '方法不会')
              .length,
          1);
      expect(
          repo.records
              .where((r) => r.questionId == 'qc' && r.cause == '方法不会')
              .first
              .status,
          CauseStatus.pending);
      expect(repo.records.where((r) => r.questionId == 'qb').length, 0);

      await tester.tap(find.text('开始复习'));
      await tester.pumpAndSettle();
      expect(goReviewCalls, 1);
    });

    testWidgets('只勾无错因的题：全部跳过，不给开始复习入口',
        (tester) async {
      final repo = reviewRepo();
      await pumpWrongbook(tester, repo: repo);
      await openMathListCompact(tester);
      await openBatchBar(tester);
      // 复选框顺序：全选、qa 批量、qb 批量、qc 批量……
      // （按收集时间新→旧；每行只剩批量框，十七批 P2：导出方框已废）。
      // qb 的批量框是第 2 个。
      await tester.tap(find.byType(Checkbox).at(2));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 道'), findsOneWidget);

      await tester.tap(find.text('加入复习'));
      await tester.pumpAndSettle();

      expect(find.text('1 道已无未解决错因，跳过'), findsOneWidget);
      expect(find.text('开始复习'), findsNothing);
    });

    testWidgets('全部加入：作用域是当前筛选结果，不限当前页',
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
      await pumpWrongbook(tester, repo: repo);
      await openMathList(tester);
      // 默认每页 10 道，只显示 10 张卡；不用勾选直接全部加入。
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部加入复习'));
      await tester.pumpAndSettle();

      expect(find.text('已加入复习 12 道'), findsOneWidget);
      expect(repo.questions.every((q) => q.reviewJoined), isTrue);
    });

    testWidgets('全部加入 + 错因筛选：只加筛出的错因的题',
        (tester) async {
      final repo = reviewRepo();
      await pumpWrongbook(tester, repo: repo);
      await openMathListCompact(tester);
      await tester.tap(find.text('筛选 ▾'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<String>).at(2));
      await tester.pumpAndSettle();
      await tester.tap(find.text('方法不会').last);
      await tester.pumpAndSettle();
      expect(find.text('待解决乙'), findsOneWidget);
      expect(find.text('待解决甲'), findsNothing);

      await openBatchBar(tester);
      await tester.tap(find.text('全部加入复习'));
      await tester.pumpAndSettle();

      expect(find.text('已加入复习 1 道'), findsOneWidget);
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
            status: CauseStatus.pending,
            joinedAt: now,
          ),
          CauseRecord(
            questionId: 'qb',
            cause: '方法不会',
            subjectId: 'math',
            status: CauseStatus.pending,
            joinedAt: now,
          ),
        ],
        counts: const {'math': (0, 0, 0)},
      );
      await pumpWrongbook(tester, repo: repo);
      await openMathListCompact(tester);
      await openBatchBar(tester);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('取消加入复习'));
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

/// 错题本 widget 测试用的 FakeRepo 子类：只覆盖 setReviewJoined，
/// 与真实 AppDatabase.setReviewJoinedInto 同语义的内存模拟
///（无错因加不进；加入时给尚无记录的错因补一条待解决记录，已有
/// 记录不动；取消只翻标志、记录保留）。批量判定与计数走真实的
/// QuestionRepository.joinReviewBatch / cancelReviewBatch。
class _B116Repo extends FakeWrongbookRepo {
  _B116Repo({
    required super.questions,
    required super.folderList,
    super.records = const [],
    super.counts = const {},
  });

  @override
  Future<bool> setReviewJoined(Question q, bool joined) async {
    if (joined && q.allCauses.isEmpty) return false;
    final i = questions.indexWhere((x) => x.id == q.id);
    if (i >= 0) questions[i] = questions[i].copyWith(reviewJoined: joined);
    if (joined) {
      for (final c in q.allCauses) {
        if (!records.any((r) => r.questionId == q.id && r.cause == c)) {
          records.add(
            CauseRecord(
              questionId: q.id,
              cause: c,
              subjectId: q.subjectId,
              joinedAt: DateTime.now(),
            ),
          );
        }
      }
    }
    return true;
  }
}
