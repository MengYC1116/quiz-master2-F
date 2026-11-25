// P0B1 归档口径统一（第一批第 3 项）+ 错题本切片占位传 subject（第 2 项收尾）。
//
// 背景：复习页 B6 主列表排除已归档题，但复查提醒用的
// recheckDueCauseCount 仍用 all(includeArchived: true)，会把归档题
// 算进去，与复习列表对不上。改后默认排除归档（includeArchived: false），
// 取消归档后恢复计入。
//
// 2026-11-26 面 C：dueToday / homeRevCounts / subjectCounts 三组
// 归档断言随方法本体删除而删除（归档排除语义现由 fsrsDueQuestionIds
// 承接，见 fsrs_due_counts_by_subject_test.dart）；本文件只保留
// recheckDueCauseCount 的归档断言与板子行学科圆点断言。
//
// 错题本板子行学科圆点现传 `_subjectOf(q.subjectId).color`；本文件
// 用页级测试直接读板子行圆点的颜色验证接线（大卡片 / 紧凑列表
// 已随视图切换去掉，旧三处切片调用点随之消失，见十九批 C）。
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';

import 'p0b1_subject_sync_test.dart' show chemPurple, subjects4;
import 'wrongbook_page_test.dart'
    show FakeWrongbookRepo, boardRowDotColor, openSubjectList, pumpWrongbook,
        wbq;

class _ArchivedFakeRepo extends QuestionRepository {
  _ArchivedFakeRepo() : super(AppDatabase.instance);

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

Question _aq(String id,
        {bool archived = false,
        String subjectId = 'math',
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
      isArchived: archived,
      sliceKind: 'limit',
      sliceText: '题',
    );

CauseRecord _ar(String qid,
        {CauseStatus status = CauseStatus.pending, DateTime? recheckDate}) =>
    CauseRecord(
      questionId: qid,
      cause: '概念不清',
      subjectId: 'math',
      status: status,
      solvedCount: status == CauseStatus.solved ? 2 : 0,
      recheckDate: recheckDate,
      joinedAt: DateTime(2026, 11, 1),
    );

void main() {
  group('P0B1 归档口径统一：归档题不计入复查提醒', () {
    test('recheckDueCauseCount（复查提醒）：只到复查日的已解决错因，归档后不计',
        () async {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final repo = _ArchivedFakeRepo()
        ..questions = [_aq('q1')]
        ..records = [_ar('q1', status: CauseStatus.solved,
            recheckDate: yesterday)];
      expect(await repo.recheckDueCauseCount(), 1);
      repo.questions = [_aq('q1', archived: true)];
      expect(await repo.recheckDueCauseCount(), 0);
      expect(await repo.recheckDueCauseCount(includeArchived: true), 1);
      repo.questions = [_aq('q1')];
      expect(await repo.recheckDueCauseCount(), 1);
    });

    test('未加入复习 / 未整理的归档题本来就不计，改动不影响', () async {
      final repo = _ArchivedFakeRepo()
        ..questions = [
          _aq('q1', joined: false),
          _aq('q2', organized: false),
        ]
        ..records = [_ar('q1'), _ar('q2')];
      expect(await repo.recheckDueCauseCount(), 0);
    });
  });

  group('P0B1 错题本板子行：学科圆点传了库里学科', () {
    // 十九批 C：大卡片 / 紧凑列表已随视图切换去掉（D-219），三处
    // 切片调用点随之消失；学科同步断言改到板子行学科圆点上
    //（圆点色 = subjectOf(q.subjectId).color，走库里学科的存色）。
    testWidgets('板子行学科圆点拿到化学学科（非数学兜底）',
        (tester) async {
      final repo = FakeWrongbookRepo(
        questions: [
          wbq('qc1', '化学平衡',
              subjectId: 'subject-chem',
              folderIds: const ['f1'],
              errorTypes: const ['概念不清'],
              sliceText: '题：化学平衡移动'),
        ],
        folderList: [
          Folder(id: 'f1', name: '试卷', subjectId: 'subject-chem'),
        ],
        subjects: subjects4,
      );
      await pumpWrongbook(tester,
          repo: repo, initialSubjectId: 'subject-chem');
      // 二十三批 D-250：只带学科落目录，点「全部题目」进列表再断言板子行。
      await openSubjectList(tester);
      expect(boardRowDotColor(tester, 'qc1'), chemPurple);
    });

    testWidgets('板子行两道题的学科圆点都拿到化学学科', (tester) async {
      final repo = FakeWrongbookRepo(
        questions: [
          wbq('qc1', '化学平衡',
              subjectId: 'subject-chem',
              folderIds: const ['f1'],
              errorTypes: const ['概念不清'],
              sliceText: '题：化学平衡移动'),
          wbq('qc2', '化学键',
              subjectId: 'subject-chem',
              folderIds: const ['f1'],
              errorTypes: const ['计算错误'],
              sliceText: '题：化学键能'),
        ],
        folderList: [
          Folder(id: 'f1', name: '试卷', subjectId: 'subject-chem'),
        ],
        subjects: subjects4,
      );
      await pumpWrongbook(tester,
          repo: repo, initialSubjectId: 'subject-chem');
      // 二十三批 D-250：只带学科落目录，点「全部题目」进列表再断言板子行。
      await openSubjectList(tester);
      expect(boardRowDotColor(tester, 'qc1'), chemPurple);
      expect(boardRowDotColor(tester, 'qc2'), chemPurple);
    });
  });
}
