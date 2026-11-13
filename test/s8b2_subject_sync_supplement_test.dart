// B2 补充：S8B2 报告 §2 的 8 处未同步点全部改成读库 subjects
//（不再写死 Subject.all），对应：
// 1. 复习排序学科顺序表 review_page.dart:220-221
// 2. 复习学科筛选下拉 review_page.dart:885
// 3. 报告弱点定位 indexWhere report_page.dart:163
// 4. 报告按学科分布 report_page.dart:444-450
// 5. 报告弱点行颜色 subjectInk 补传存色 report_page.dart:622-623
// 6. subjectCounts() 初始化键 repository.dart:202
// 7. 收集中心导入学科下拉 collect_page.dart:577
// 8. 错题本紧凑行/归档行 _prowMetaLine wrongbook_page.dart:3020
//
// 颜色不断言具体色值以外的硬编码，只断言等于新学科的存色、
// 且不等于数学色（任务要求）。
// 复用各页测试文件的 FakeRepo / pump 助手（与 S8A5 同一做法）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/theme/design_tokens.dart';

import 'collect_page_test.dart' show FakeRepo, pumpCollect;
import 'report_page_test.dart' show pumpReport, reportRepo, tq, trec;
import 'review_page_test.dart'
    show FakeReviewRepo, pickMenuItem, pumpReview, rec, reviewRepo, rq;
import 'wrongbook_page_test.dart' show FakeWrongbookRepo, pumpWrongbook, wbq;

/// 新学科：化学，紫 0xFF7C5CFC（与 B2 测试、学科管理轮换表第 4 位同值）。
const chemPurple = Color(0xFF7C5CFC);
final chemSubject =
    Subject(id: 'subject-chem', name: '化学', color: chemPurple, icon: '化');
final histSubject = Subject(
    id: 'subject-hist', name: '历史', color: const Color(0xFFF08A1D), icon: '历');
final subjects4 = [...Subject.all, chemSubject];
final subjects5 = [...Subject.all, chemSubject, histSubject];

/// 在全部 RichText 里找一段恰好是 [text] 的 TextSpan，返回它的颜色；
/// 找不到返回 null。弱点行标题、紧凑行明细行都是 TextSpan 着色。
Color? spanColorFor(WidgetTester tester, String text) {
  for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
    final found = _findSpan(rt.text as TextSpan, text);
    if (found != null) return found.style?.color;
  }
  return null;
}

TextSpan? _findSpan(TextSpan span, String text) {
  if (span.text == text) return span;
  for (final c in span.children ?? const <InlineSpan>[]) {
    if (c is TextSpan) {
      final f = _findSpan(c, text);
      if (f != null) return f;
    }
  }
  return null;
}

/// subjectCounts 专用 Fake：覆盖 all / causeRecords / subjects，
/// 不碰真实数据库（subjectCounts 原先直读 _db.allCauseRecords，
/// 本次改走仓库方法 causeRecords，行为不变，见 repository.dart）。
class FakeCountsRepo extends QuestionRepository {
  FakeCountsRepo({
    required this.questions,
    required this.records,
    required this.subjectsValue,
  }) : super(AppDatabase.instance);

  List<Question> questions;
  List<CauseRecord> records;
  List<Subject> subjectsValue;

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

  @override
  Future<List<Subject>> subjects() async => List.of(subjectsValue);
}

void main() {
  group('6. subjectCounts', () {
    test('新学科有计数键，不再缺键变 0', () async {
      final repo = FakeCountsRepo(
        subjectsValue: subjects4,
        questions: [
          rq('q-chem-1', '化学平衡移动',
              subjectId: 'subject-chem',
              errorTypes: const ['概念不清'],
              reviewJoined: true),
          rq('q-m1', '函数极限',
              errorTypes: const ['概念不清'], reviewJoined: true),
        ],
        records: [
          rec('q-chem-1', '概念不清', subjectId: 'subject-chem'),
          rec('q-m1', '概念不清',
              status: CauseStatus.solved, solvedCount: 2),
        ],
      );
      final counts = await repo.subjectCounts();
      expect(counts.containsKey('subject-chem'), isTrue);
      expect(counts['subject-chem'], (1, 0, 0));
      expect(counts['math'], (0, 0, 1));
      expect(counts['english'], (0, 0, 0));
    });
  });

  group('1+2. 复习', () {
    testWidgets('按学科排序：两个新学科按入库顺序排，不再同落 99 位',
        (tester) async {
      // 加入时间故意倒过来：旧代码下两科同落 99 位、按加入时间排，
      // 历史（11-9）会排在化学（11-10）前面；新代码按入库顺序排，
      // 化学（第 4 位）在历史（第 5 位）前面。
      final repo = FakeReviewRepo(
        settings: AppSettings.defaults.copyWith(reviewSort: 'subject'),
        subjects: subjects5,
        questions: [
          rq('q-chem', '化学平衡移动',
              subjectId: 'subject-chem',
              errorTypes: const ['概念不清'],
              reviewJoined: true),
          rq('q-hist', '历史时间轴',
              subjectId: 'subject-hist',
              errorTypes: const ['概念不清'],
              reviewJoined: true),
        ],
        records: [
          rec('q-chem', '概念不清',
              subjectId: 'subject-chem',
              joinedAt: DateTime(2026, 11, 10)),
          rec('q-hist', '概念不清',
              subjectId: 'subject-hist',
              joinedAt: DateTime(2026, 11, 9)),
        ],
      );
      await pumpReview(tester, repo: repo);
      final chemDy =
          tester.getTopLeft(find.textContaining('化学平衡移动')).dy;
      final histDy = tester.getTopLeft(find.textContaining('历史时间轴')).dy;
      expect(chemDy, lessThan(histDy));
    });

    testWidgets('学科筛选下拉：新学科出现且能选中过滤', (tester) async {
      final repo = reviewRepo();
      repo.subjectsValue = subjects4;
      repo.questions = [
        ...repo.questions,
        rq('q-chem', '化学平衡移动',
            subjectId: 'subject-chem',
            errorTypes: const ['概念不清'],
            reviewJoined: true),
      ];
      repo.records = [
        ...repo.records,
        rec('q-chem', '概念不清', subjectId: 'subject-chem'),
      ];
      await pumpReview(tester, repo: repo);
      await pickMenuItem<String>(tester,
          find.byType(DropdownButton<String>).first, 'subject-chem');
      expect(find.textContaining('化学平衡移动'), findsOneWidget);
      expect(find.textContaining('函数极限'), findsNothing);
    });
  });

  group('3+4+5. 学习报告', () {
    testWidgets('按学科分布：新学科出现且计数正确', (tester) async {
      final repo = reportRepo();
      repo.subjectsValue = subjects4;
      repo.questions = [
        ...repo.questions,
        tq('q-chem', '化学平衡移动',
            subjectId: 'subject-chem', errorTypes: const ['概念不清']),
      ];
      repo.records = [
        ...repo.records,
        trec('q-chem', '概念不清', subjectId: 'subject-chem'),
      ];
      await pumpReport(tester, repo: repo);
      expect(find.text('化学 · 1 道错题'), findsOneWidget);
    });

    testWidgets('弱点行：新学科名与颜色走存色，不等于数学色', (tester) async {
      // 化学 2 道同错因 → 弱点组计数 2，排进 Top 5 首行。
      final repo = reportRepo();
      repo.subjectsValue = subjects4;
      repo.questions = [
        ...repo.questions,
        tq('q-chem-1', '化学平衡移动',
            subjectId: 'subject-chem', errorTypes: const ['概念不清']),
        tq('q-chem-2', '氧化还原配平',
            subjectId: 'subject-chem', errorTypes: const ['概念不清']),
      ];
      repo.records = [
        ...repo.records,
        trec('q-chem-1', '概念不清', subjectId: 'subject-chem'),
        trec('q-chem-2', '概念不清', subjectId: 'subject-chem'),
      ];
      await pumpReport(tester, repo: repo);
      final color = spanColorFor(tester, '化学');
      expect(color, chemPurple);
      expect(color, isNot(DesignTokens.of(Brightness.light).mathInk));
    });
  });

  group('7. 收集中心', () {
    testWidgets('导入学科下拉：新学科出现且能选中', (tester) async {
      final repo = FakeRepo([], subjects: subjects4);
      await pumpCollect(tester, repo: repo);
      await tester.tap(find.byKey(const Key('collect-subject-select')));
      await tester.pumpAndSettle();
      expect(find.text('化学'), findsOneWidget);
      await tester.tap(find.text('化学'));
      await tester.pumpAndSettle();
      // 选中后下拉按钮显示化学，不再是“请选择学科”。
      expect(find.text('化学'), findsOneWidget);
      expect(find.text('请选择学科'), findsNothing);
    });
  });

  group('8. 错题本紧凑行', () {
    testWidgets('紧凑行明细行：新学科名与颜色走存色，不等于数学色',
        (tester) async {
      final repo = FakeWrongbookRepo(
        questions: [
          wbq('q-chem-1', '化学平衡移动',
              subjectId: 'subject-chem',
              folderIds: const ['f-chem'],
              errorTypes: const ['概念不清'],
              tags: const ['易错']),
        ],
        folderList: const [
          Folder(id: 'f-chem', name: '试卷', subjectId: 'subject-chem'),
        ],
        subjects: subjects4,
      );
      await pumpWrongbook(tester,
          repo: repo, initialSubjectId: 'subject-chem');
      await tester.tap(find.text('全部题目'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('紧凑列表'));
      await tester.pumpAndSettle();
      final color = spanColorFor(tester, '化学');
      expect(color, chemPurple);
      expect(color, isNot(DesignTokens.of(Brightness.light).mathInk));
    });
  });
}
