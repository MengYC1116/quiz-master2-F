// P0B1 学科同步扫尾（第一批第 2 项）：
// 详情 / 整理 / 首页 / 切片占位以前直接 Subject.byId，未知学科 id
// 回退到“数学”。本文件新建一个学科（化学）并建一道该学科的题，
// 验证各处都不再显示成“数学”。
//
// 化学学科与 s8_chip_label_test / s8b2 系列同值：
// id 'subject-chem'、名“化学”、存色紫 0xFF7C5CFC（轮换表第 4 位）、
// 图标“化”。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/widgets.dart';

import 'detail_page_test.dart' show FakeDetailRepo, dtq, pumpDetail;
import 'home_page_test.dart' show FakeRepo, pumpHome;
import 'organize_page_test.dart' show FakeOrganizeRepo, pumpOrganize, q;

const chemPurple = Color(0xFF7C5CFC);
final chemSubject =
    Subject(id: 'subject-chem', name: '化学', color: chemPurple, icon: '化');
final subjects4 = [...Subject.all, chemSubject];

Future<void> _pumpSlice(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      home: Scaffold(body: Center(child: child)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('P0B1 学科同步扫尾：新学科化学不再显示成数学', () {
    testWidgets('整理页顶部：当前整理显示“化学 · 化学平衡”', (tester) async {
      final repo = FakeOrganizeRepo(
        questions: [
          q('qc1', '化学平衡',
              subjectId: 'subject-chem',
              sliceKind: 'limit',
              sliceText: '题：化学平衡移动',
              createdAt: DateTime(2026, 11, 8)),
        ],
        folderList: const [],
        subjectsValue: subjects4,
      );
      await pumpOrganize(tester, repo: repo);
      expect(
        find.textContaining('化学 · 化学平衡', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('数学'), findsNothing);
    });

    testWidgets('整理页队列搜索：搜“化学”找到化学题，搜“数学”找不到',
        (tester) async {
      final repo = FakeOrganizeRepo(
        questions: [
          q('qc1', '化学平衡',
              subjectId: 'subject-chem',
              sliceKind: 'limit',
              sliceText: '题：化学平衡移动',
              createdAt: DateTime(2026, 11, 8)),
        ],
        folderList: const [],
        subjectsValue: subjects4,
      );
      await pumpOrganize(tester, repo: repo);
      await tester.tap(find.text('队列'));
      await tester.pumpAndSettle();
      final searchField = find.byWidgetPredicate(
        (w) =>
            w is TextField && w.decoration?.hintText == '搜题名、学科、试卷',
      );
      await tester.enterText(searchField, '化学');
      await tester.pumpAndSettle();
      expect(find.text('化学平衡'), findsOneWidget);
      expect(find.textContaining('搜到 1 道'), findsOneWidget);
      // 搜“数学”：化学题的学科名是化学，不应被搜到。
      await tester.enterText(searchField, '数学');
      await tester.pumpAndSettle();
      expect(find.text('没找到这道题，换个词试试'), findsOneWidget);
    });

    testWidgets('详情页：标题与副标题学科字段显示“化学”', (tester) async {
      final repo = FakeDetailRepo(
        questions: [
          dtq('qc1', '化学平衡',
              subjectId: 'subject-chem',
              sliceKind: 'limit',
              sliceText: '题：化学平衡移动',
              errorTypes: const ['概念不清'],
              createdAt: DateTime.now().subtract(const Duration(days: 2))),
        ],
        subjectsValue: subjects4,
      );
      await pumpDetail(tester,
          repo: repo, questionId: 'qc1', orderIds: const ['qc1']);
      // 标题：学科 · 题型｜题名。
      expect(find.text('化学 · 极限题｜化学平衡'), findsOneWidget);
      // 副标题：学科只读说明里的学科名是单独的 Text('化学')。
      expect(find.text('化学'), findsWidgets);
      expect(find.textContaining('数学'), findsNothing);
    });

    testWidgets('首页“上次停在”：副标题与焦点卡都显示“化学”',
        (tester) async {
      final repo = FakeRepo()
        ..subjectsList = subjects4
        ..recent = (
          kind: '整理',
          subjectId: 'subject-chem',
          title: '化学平衡',
        );
      await pumpHome(tester, repo: repo);
      expect(find.text('上次停在：整理工作台 · 化学「化学平衡」'),
          findsOneWidget);
      expect(find.text('继续上次：整理工作台 · 化学「化学平衡」'),
          findsOneWidget);
    });

    testWidgets('切片失败占位：传了库里学科，显示“化”+“化学 · 极限题”',
        (tester) async {
      final chemQ = q('qc1', '化学平衡',
          subjectId: 'subject-chem',
          sliceKind: 'limit',
          sliceText: '题：化学平衡移动');
      await _pumpSlice(
        tester,
        QuestionSlice(question: chemQ, failed: true, subject: chemSubject),
      );
      expect(find.text('化'), findsOneWidget);
      expect(find.text('化学 · 极限题'), findsOneWidget);
      expect(find.textContaining('数学'), findsNothing);
    });

    testWidgets('紧凑缩略图失败占位：传了库里学科，显示“化”+“加载失败”',
        (tester) async {
      final chemQ = q('qc1', '化学平衡',
          subjectId: 'subject-chem',
          sliceKind: 'limit',
          sliceText: '题：化学平衡移动');
      await _pumpSlice(
        tester,
        CompactSliceThumb(
            question: chemQ, failed: true, subject: chemSubject),
      );
      expect(find.text('化'), findsOneWidget);
      expect(find.text('加载失败'), findsOneWidget);
      expect(find.textContaining('数学'), findsNothing);
    });

    testWidgets('切片未传 subject 时仍回退旧行为（数学兜底，不崩）',
        (tester) async {
      final chemQ = q('qc1', '化学平衡',
          subjectId: 'subject-chem',
          sliceKind: 'limit',
          sliceText: '题：化学平衡移动');
      await _pumpSlice(
        tester,
        QuestionSlice(question: chemQ, failed: true),
      );
      // 兜底是已知行为：调用方不传 subject 时仍显示数学（错题本
      // 三处调用点未改，见 P0B1 报告 §5 残留）。
      expect(find.text('数学 · 极限题'), findsOneWidget);
    });
  });
}
