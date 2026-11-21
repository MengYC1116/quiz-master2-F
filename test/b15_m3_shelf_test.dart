// 十五批 M3：书架页顶栏「新建导出单」入口（D-169）。
//
// 0 题时按钮置灰 + 提示「先筛选出题目」；有题时可点，点开 D-168 向导
// （第 1 步选范围）；向导内取消即丢弃本次选择。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/wrongbook/wrongbook_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/uikit.dart';

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

  @override
  Future<Map<String, (int, int, int)>> subjectCounts({
    bool includeArchived = false,
  }) async => const {};

  @override
  Future<List<CauseRecord>> causeRecords() async => const [];

  @override
  Future<AppSettings> settings() async => const AppSettings();
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
          onOpenDetail: (_, __) async {},
          onGoReview: ({String? subjectId}) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('书架页顶栏「新建导出单」入口', () {
    testWidgets('有题时按钮可用，点开向导第 1 步', (tester) async {
      await pumpShelf(
        tester,
        ShelfFakeRepo(questions: [shelfQ('q1'), shelfQ('q2')]),
      );
      final button = tester.widget<QmButton>(
        find.byKey(const Key('new-export-order')),
      );
      expect(button.onPressed, isNotNull);
      await tester.tap(find.byKey(const Key('new-export-order')));
      await tester.pumpAndSettle();
      expect(find.text('新建导出单 · 第 1 步：选范围'), findsOneWidget);
      expect(find.text('圈定 2 道题'), findsOneWidget);
      // 向导内取消：对话框关闭，回到书架。
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('新建导出单 · 第 1 步：选范围'), findsNothing);
      expect(find.text('错题本'), findsOneWidget);
    });

    testWidgets('0 题时按钮置灰 + 提示「先筛选出题目」', (tester) async {
      await pumpShelf(tester, ShelfFakeRepo(questions: []));
      final button = tester.widget<QmButton>(
        find.byKey(const Key('new-export-order')),
      );
      expect(button.onPressed, isNull);
      expect(find.text('先筛选出题目'), findsOneWidget);
    });
  });
}
