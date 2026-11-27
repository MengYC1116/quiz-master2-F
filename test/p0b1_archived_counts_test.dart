// P0B1 归档口径统一（第一批第 3 项）+ 错题本切片占位传 subject（第 2 项收尾）。
//
// 背景：复习页 B6 主列表排除已归档题；提醒计数源原用的
// recheckDueCauseCount（数错因）已随 FSRS 全量迁移包 3 删除，
// 归档断言改由 `fsrsDueTotal` 承接，见 test/s8b4_reminder_test.dart
// 的 `fsrsDueTotal（提醒计数源）` 组（含“归档题不计入，取消归档后
// 恢复计入”）；本文件只保留板子行学科圆点断言。
//
// 2026-11-26 面 C：dueToday / homeRevCounts / subjectCounts 三组
// 归档断言随方法本体删除而删除（归档排除语义现由 fsrsDueQuestionIds
// 承接，见 fsrs_due_counts_by_subject_test.dart）。
//
// 错题本板子行学科圆点现传 `_subjectOf(q.subjectId).color`；本文件
// 用页级测试直接读板子行圆点的颜色验证接线（大卡片 / 紧凑列表
// 已随视图切换去掉，旧三处切片调用点随之消失，见十九批 C）。
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';

import 'p0b1_subject_sync_test.dart' show chemPurple, subjects4;
import 'wrongbook_page_test.dart'
    show FakeWrongbookRepo, boardRowDotColor, openSubjectList, pumpWrongbook,
        wbq;

void main() {
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
