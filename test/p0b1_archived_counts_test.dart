// P0B1 归档口径统一（第一批第 3 项）+ 错题本切片占位传 subject（第 2 项收尾）。
//
// 背景：复习页 B6 主列表排除已归档题，但 repository.dueToday /
// recheckDueCauseCount / subjectCounts 仍用 all(includeArchived: true)，
// 首页“要复习”、导航速览（homeRevCounts）、复查提醒、错题本封面三数
// 会把归档题算进去，与复习列表对不上。改后三者默认排除归档
//（includeArchived: false），取消归档后恢复计入。
//
// 错题本三处切片调用点（大卡片 QuestionSlice、紧凑列表两处
// CompactSliceThumb）现传 `_subjectOf(q.subjectId)`；本文件用页级
// 测试直接读树上 widget 的 subject 参数验证接线（错题本页本身不传
// failed，失败占位靠 widget 的 failed 开关，已由
// p0b1_subject_sync_test 的切片占位测试覆盖）。
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/widgets/widgets.dart';

import 'p0b1_subject_sync_test.dart' show subjects4;
import 'wrongbook_page_test.dart'
    show FakeWrongbookRepo, pumpWrongbook, wbq;

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
  group('P0B1 归档口径统一：归档题不计入要复习 / 复查 / 封面三数', () {
    test('dueToday：归档后排除，显式 includeArchived 仍包含，取消归档恢复',
        () async {
      final repo = _ArchivedFakeRepo()
        ..questions = [_aq('q1')]
        ..records = [_ar('q1')];
      expect((await repo.dueToday()).map((q) => q.id), ['q1']);
      // 归档 → 默认口径不再计入。
      repo.questions = [_aq('q1', archived: true)];
      expect(await repo.dueToday(), isEmpty);
      // 显式 opt-in 仍能拿到（供以后确有需要的调用方）。
      expect((await repo.dueToday(includeArchived: true)).map((q) => q.id),
          ['q1']);
      // 取消归档 → 恢复计入。
      repo.questions = [_aq('q1')];
      expect((await repo.dueToday()).map((q) => q.id), ['q1']);
    });

    test('homeRevCounts（首页 + 导航速览）：归档后数学计数归零，取消归档恢复',
        () async {
      final repo = _ArchivedFakeRepo()
        ..questions = [_aq('q1')]
        ..records = [_ar('q1')];
      expect((await repo.homeRevCounts())['math'], 1);
      repo.questions = [_aq('q1', archived: true)];
      expect((await repo.homeRevCounts())['math'], 0);
      repo.questions = [_aq('q1')];
      expect((await repo.homeRevCounts())['math'], 1);
    });

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

    test('subjectCounts（错题本封面三数）：归档后要复习 / 待复查归零，取消归档恢复',
        () async {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final repo = _ArchivedFakeRepo()
        ..questions = [_aq('q1'), _aq('q2')]
        ..records = [
          _ar('q1'),
          _ar('q2', status: CauseStatus.solved, recheckDate: yesterday),
        ];
      // q1 待解决 → 要复习 1；q2 已解决且到复查日 → 待复查 1、要复习 0。
      var counts = await repo.subjectCounts();
      expect(counts['math'], (1, 1, 0));
      // q1 归档 → 要复习归零，待复查仍是 q2 的 1。
      repo.questions = [_aq('q1', archived: true), _aq('q2')];
      counts = await repo.subjectCounts();
      expect(counts['math'], (0, 1, 0));
      // q2 也归档 → 全部归零。
      repo.questions = [_aq('q1', archived: true), _aq('q2', archived: true)];
      counts = await repo.subjectCounts();
      expect(counts['math'], (0, 0, 0));
      // 取消归档 → 恢复。
      repo.questions = [_aq('q1'), _aq('q2')];
      counts = await repo.subjectCounts();
      expect(counts['math'], (1, 1, 0));
    });

    test('未加入复习 / 未整理的归档题本来就不计，改动不影响', () async {
      final repo = _ArchivedFakeRepo()
        ..questions = [
          _aq('q1', joined: false),
          _aq('q2', organized: false),
        ]
        ..records = [_ar('q1'), _ar('q2')];
      expect(await repo.dueToday(), isEmpty);
      expect((await repo.homeRevCounts())['math'], 0);
      expect(await repo.recheckDueCauseCount(), 0);
    });
  });

  group('P0B1 错题本切片占位：三处调用点传了库里学科', () {
    testWidgets('大卡片 QuestionSlice 拿到化学学科（非数学兜底）',
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
      await pumpWrongbook(tester, repo: repo);
      await tester.tap(find.text('化学'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部题目'));
      await tester.pumpAndSettle();
      final slice =
          tester.widget<QuestionSlice>(find.byType(QuestionSlice).first);
      expect(slice.subject?.id, 'subject-chem');
      expect(slice.subject?.name, '化学');
      expect(slice.subject?.icon, '化');
    });

    testWidgets('紧凑列表 CompactSliceThumb 两处都拿到化学学科',
        (tester) async {
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
      await pumpWrongbook(tester, repo: repo);
      await tester.tap(find.text('化学'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部题目'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('紧凑列表'));
      await tester.pumpAndSettle();
      final thumbs =
          tester.widgetList<CompactSliceThumb>(find.byType(CompactSliceThumb));
      expect(thumbs.length, 2);
      for (final t in thumbs) {
        expect(t.subject?.id, 'subject-chem');
        expect(t.subject?.name, '化学');
      }
    });
  });
}
