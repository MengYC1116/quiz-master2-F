// S8 QmChip / SubjectLabel 只认三科 id 修复：
// QmChip 加 storedColor（S8A2 的 stored 思路），SubjectLabel 加
// subject 对象；未传时保持旧行为（预设三科走主题固定色）。
// 另覆盖调用点：收集任务行、复习组行、报告“接下来练什么”句、
// 错题本目录标题（B2 补充报告 §3 表）。
//
// 颜色不断言具体色值以外的硬编码，只断言等于新学科的存色、
// 且不等于数学色（任务要求）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/uikit.dart';
import 'package:quiz_master2/widgets/widgets.dart';

import 'collect_page_test.dart' show FakeRepo, pumpCollect;
import 'report_page_test.dart'
    show FakeReportRepo, pumpReport, tq, trec;
import 'review_page_test.dart'
    show FakeReviewRepo, pumpReview, rec, rq;
import 'wrongbook_page_test.dart'
    show FakeWrongbookRepo, pumpWrongbook, wbq;

/// 新学科：化学，紫 0xFF7C5CFC（与 B2 / B2 补充测试同值，轮换表第 4 位）。
const chemPurple = Color(0xFF7C5CFC);
final chemSubject =
    Subject(id: 'subject-chem', name: '化学', color: chemPurple, icon: '化');
final subjects4 = [...Subject.all, chemSubject];

/// QmChip 内所有 Container 装饰色（选中填充即其中之一）。
Set<Color> _chipFillColors(WidgetTester tester) {
  final colors = <Color>{};
  for (final c in tester.widgetList<Container>(
      find.descendant(of: find.byType(QmChip), matching: find.byType(Container)))) {
    final d = c.decoration;
    if (d is BoxDecoration && d.color != null) colors.add(d.color!);
  }
  return colors;
}

/// SubjectLabel 圆点的颜色。
Color? _labelDotColor(WidgetTester tester) {
  for (final c in tester.widgetList<Container>(find.descendant(
      of: find.byType(SubjectLabel), matching: find.byType(Container)))) {
    final d = c.decoration;
    if (d is BoxDecoration && d.shape == BoxShape.circle && d.color != null) {
      return d.color;
    }
  }
  return null;
}

Future<void> _pumpChip(
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
  group('QmChip', () {
    testWidgets('新学科：选中填充等于存色紫，不等于数学色（亮/深）',
        (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        await _pumpChip(
          tester,
          QmChip(
            label: '化学',
            subjectId: 'subject-chem',
            storedColor: chemPurple,
            selected: true,
            onTap: () {},
          ),
          brightness: brightness,
        );
        final fills = _chipFillColors(tester);
        expect(fills, contains(chemPurple));
        expect(
          fills,
          isNot(contains(
              DesignTokens.subjectColor('math', brightness))),
        );
      }
    });

    testWidgets('新学科展示态：选中填充同样等于存色紫', (tester) async {
      await _pumpChip(
        tester,
        QmChip(
          label: '化学',
          subjectId: 'subject-chem',
          storedColor: chemPurple,
          selected: true,
          displayOnly: true,
        ),
      );
      expect(_chipFillColors(tester), contains(chemPurple));
    });

    testWidgets('预设三科行为不变：传了存色也仍走主题固定色',
        (tester) async {
      await _pumpChip(
        tester,
        QmChip(
          label: '数学',
          subjectId: 'math',
          storedColor: chemPurple,
          selected: true,
          onTap: () {},
        ),
      );
      final fills = _chipFillColors(tester);
      expect(
        fills,
        contains(DesignTokens.subjectColor('math', Brightness.light)),
      );
      expect(fills, isNot(contains(chemPurple)));
    });

    testWidgets('不传存色：旧行为不变，新学科仍按 id 查表落到数学色',
        (tester) async {
      await _pumpChip(
        tester,
        QmChip(
          label: '化学',
          subjectId: 'subject-chem',
          selected: true,
          onTap: () {},
        ),
      );
      expect(
        _chipFillColors(tester),
        contains(DesignTokens.subjectColor('math', Brightness.light)),
      );
    });
  });

  group('SubjectLabel', () {
    testWidgets('新学科：显示“化学”+存色紫（亮/深）', (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        await _pumpChip(
          tester,
          SubjectLabel(subjectId: 'subject-chem', subject: chemSubject),
          brightness: brightness,
        );
        expect(find.text('化学'), findsOneWidget);
        expect(_labelDotColor(tester), chemPurple);
        final text =
            tester.widget<Text>(find.text('化学'));
        expect(text.style?.color, chemPurple);
      }
    });

    testWidgets('预设三科行为不变：不传 subject 仍显示数学+数学色',
        (tester) async {
      await _pumpChip(tester, const SubjectLabel(subjectId: 'math'));
      expect(find.text('数学'), findsOneWidget);
      expect(_labelDotColor(tester),
          DesignTokens.subjectColor('math', Brightness.light));
    });

    testWidgets('subjectLabelColor：新学科传存色亮/深都直接用存色',
        (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        await _pumpChip(
          tester,
          Builder(
            builder: (context) => Text(
              subjectLabelColor(context, 'subject-chem', chemPurple)
                      .toARGB32()
                      .toString(),
            ),
          ),
          brightness: brightness,
        );
        expect(find.text(chemPurple.toARGB32().toString()), findsOneWidget);
      }
    });
  });

  group('调用点：新学科不再显示成数学', () {
    testWidgets('收集任务行：化学任务显示“化学”+紫', (tester) async {
      final repo = FakeRepo(
        [
          CollectTask(
            id: 't-chem',
            name: '化学讲义.pdf · 第1页 · 第1题',
            fileName: '化学讲义.pdf',
            subjectId: 'subject-chem',
            status: CollectStatus.queued,
          ),
        ],
        subjects: subjects4,
      );
      await pumpCollect(tester, repo: repo);
      expect(find.text('化学'), findsOneWidget);
      expect(_labelDotColor(tester), chemPurple);
    });

    testWidgets('复习组行：化学组显示“化学”+紫', (tester) async {
      final repo = FakeReviewRepo(
        subjects: subjects4,
        questions: [
          rq('q-chem-1', '化学平衡移动',
              subjectId: 'subject-chem',
              errorTypes: const ['概念不清'],
              reviewJoined: true),
        ],
        records: [
          rec('q-chem-1', '概念不清', subjectId: 'subject-chem'),
        ],
      );
      await pumpReview(tester, repo: repo);
      final text = tester.widget<Text>(find.text('化学'));
      expect(text.style?.color, chemPurple);
    });

    testWidgets('报告“接下来练什么”：最弱是化学时句子写化学',
        (tester) async {
      final today = DateTime.now();
      final day = DateTime(today.year, today.month, today.day);
      final repo = FakeReportRepo(
        subjects: subjects4,
        questions: [
          tq('q-c1', '化学平衡移动',
              subjectId: 'subject-chem',
              errorTypes: const ['概念不清'],
              createdAt: day),
          tq('q-c2', '氧化还原配平',
              subjectId: 'subject-chem',
              errorTypes: const ['概念不清'],
              createdAt: day),
        ],
        records: [
          trec('q-c1', '概念不清',
              subjectId: 'subject-chem', joinedAt: day),
          trec('q-c2', '概念不清',
              subjectId: 'subject-chem', joinedAt: day),
        ],
        kps: const [],
      );
      await pumpReport(tester, repo: repo);
      expect(find.textContaining('先解决化学的概念不清'), findsOneWidget);
      expect(find.textContaining('先解决数学的'), findsNothing);
    });

    testWidgets('错题本目录标题：化学书显示“化学 · 错题本”',
        (tester) async {
      final repo = FakeWrongbookRepo(
        subjects: subjects4,
        questions: [
          wbq('q-chem-1', '化学平衡移动', subjectId: 'subject-chem'),
        ],
        folderList: const [],
      );
      await pumpWrongbook(tester,
          repo: repo, initialSubjectId: 'subject-chem');
      expect(find.text('化学 · 错题本'), findsOneWidget);
      expect(find.text('数学 · 错题本'), findsNothing);
    });
  });
}
