// 十六批 B（D-190）：书架页顶栏「新建导出单」入口已废（D-169 作废）。
//
// 书架顶栏只留已归档入口与提示；导出改到错题本列表页直接勾选
//（入口在列表页工具栏，见 test/b16_direct_export_test.dart）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/wrongbook/wrongbook_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';

Question shelfQ(String id, {String subjectId = 'math'}) => Question(
  id: id,
  title: '题 $id',
  subjectId: subjectId,
  createdAt: DateTime(2026, 11, 20),
  isOrganized: true,
);

class ShelfFakeRepo extends QuestionRepository {
  ShelfFakeRepo({required this.questions})
    : super(AppDatabase.instance);

  List<Question> questions;

  @override
  Future<List<Subject>> subjects() async => [
    Subject.math,
    Subject.english,
    Subject.politics,
  ];

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<Folder>> folders({String? subjectId}) async => const [];

  @override
  Future<List<Exam>> exams() async => const [];

  @override
  Future<List<String>> tags() async => const [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  // 2026-11-25 口径迁移 §2.1/§4：load() 封面到期数走这里（同款 D-225：
  // 不覆写会走真实库、页面卡 loading、pumpAndSettle 超时）。
  @override
  Future<Map<String, int>> fsrsDueCountsBySubject({
    required ReviewScheduler scheduler,
    DateTime? now,
  }) async => const {};

  @override
  Future<List<CauseRecord>> causeRecords() async => const [];

  @override
  Future<AppSettings> settings() async => const AppSettings();

  // 十九批 C：内存版已存查找（A3 起 load() 读 savedSearches；不覆写
  // 会走真实库、页面卡 loading、pumpAndSettle 超时，见 D-225）。
  @override
  Future<List<SavedSearch>> savedSearches() async => const [];

  // P3 入口 1：load() 读池内标记（同款 D-225：不覆写会走真实库、
  // 页面卡 loading、pumpAndSettle 超时）。
  @override
  Future<Set<String>> fsrsPoolQuestionIds() async => const {};

  // FSRS 全量迁移包 4：load() 读下次到期表（同款 D-225：不覆写
  // 会走真实库）。
  @override
  Future<Map<String, DateTime>> fsrsNextDueByQuestion({
    required ReviewScheduler scheduler,
  }) async => const {};
}

Future<void> pumpShelf(WidgetTester tester, ShelfFakeRepo repo) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: Scaffold(
        body: WrongbookPage(
          repo: repo,
          onOpenHome: () {},
          onOpenDetail: (_, __, {String? searchContext}) async {},
          onGoReview: ({String? subjectId}) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // 二十三批 D-250：默认落点就是书架，不用再经筛选面板进。
}

void main() {
  group('书架页顶栏：向导入口已废', () {
    testWidgets('有题时也不再有「新建导出单」按钮与「先筛选出题目」提示', (
      tester,
    ) async {
      await pumpShelf(
        tester,
        ShelfFakeRepo(questions: [shelfQ('q1'), shelfQ('q2')]),
      );
      expect(find.byKey(const Key('new-export-order')), findsNothing);
      expect(find.text('新建导出单'), findsNothing);
      expect(find.text('先筛选出题目'), findsNothing);
      // 已归档入口仍在（提示文案已随文案走查批删除）。
      expect(find.textContaining('已归档'), findsOneWidget);
    });

    testWidgets('0 题时同样没有导出入口', (tester) async {
      await pumpShelf(tester, ShelfFakeRepo(questions: []));
      expect(find.byKey(const Key('new-export-order')), findsNothing);
      expect(find.text('新建导出单'), findsNothing);
    });
  });
}
