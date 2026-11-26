// 二十六批（D-256）：错题本书 12 号「双色拼接精装」一比一复刻进书架。
// 复用 wrongbook_page_test.dart 的 pumpWrongbook / threeSubjectRepo /
// openShelfFromList 与 FakeWrongbookRepo / wbq。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';

import 'wrongbook_page_test.dart';

void main() {
  group('二十六批：书 12 号复刻（D-256）', () {
    // 按学科名找各自的封面盒子（_buildBook 的 AnimatedContainer）。
    Finder bookBox(String name) => find.ancestor(
      of: find.text(name),
      matching: find.byType(AnimatedContainer),
    );

    testWidgets('学科名：Noto Serif SC 38px/900/字距 5.32', (tester) async {
      await pumpWrongbook(tester);
      await openShelfFromList(tester);
      for (final name in ['数学', '英语', '政治']) {
        final style = tester.widget<Text>(find.text(name)).style!;
        expect(style.fontFamily, 'Noto Serif SC');
        expect(style.fontSize, 38);
        expect(style.fontWeight, FontWeight.w900);
        // FontVariation 不重写 ==，按字段断言。
        expect(style.fontVariations, hasLength(1));
        expect(style.fontVariations!.first.axis, 'wght');
        expect(style.fontVariations!.first.value, 900);
        expect(style.letterSpacing, 5.32);
        expect(style.color, Colors.white);
      }
    });

    testWidgets('英文名与分布行样式按板子', (tester) async {
      await pumpWrongbook(tester);
      await openShelfFromList(tester);
      final eng = tester.widget<Text>(find.text('MATHEMATICS')).style!;
      expect(eng.fontSize, 10);
      expect(eng.fontWeight, FontWeight.w700);
      expect(eng.letterSpacing, 3.4);
      expect(eng.color, const Color.fromRGBO(255, 255, 255, 0.75));
      // 分布行：12px 白字、行高 1.5（2026-11-26，两数字行已撤下）。
      final dist = tester
          .widget<Text>(find.text('共 3 道 · 试卷 2 道 · 平时作业 1 道'))
          .style!;
      expect(dist.fontSize, 12);
      expect(dist.color, Colors.white);
      expect(dist.height, 1.5);
      // 分布行顶部分隔线：1px 白 40%（每本书一条）。
      for (final name in ['数学', '英语', '政治']) {
        expect(
          find.descendant(
            of: bookBox(name),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is Container &&
                  w.decoration is BoxDecoration &&
                  ((w.decoration as BoxDecoration).border as Border?)
                          ?.top ==
                      const BorderSide(
                        color: Color.fromRGBO(255, 255, 255, 0.4),
                      ),
            ),
          ),
          findsOneWidget,
        );
      }
    });

    testWidgets('分布行是真实数据：数学共 3 道 · 试卷 2 道 · 平时作业 1 道、英语共 2 道 · 试卷 2 道、政治共 0 道', (
      tester,
    ) async {
      await pumpWrongbook(tester);
      await openShelfFromList(tester);
      // 总数 = 该科已整理未归档未掌握题数，与文件夹计数同一口径
      // （已整理、未归档、未掌握），只留 > 0 的、按题数从多到少。
      // 数学：总数 3（q1/q2/q3；q7 已掌握不计，q5 已归档、q6 未
      // 整理不计）；试卷 2（q1/q3；q7 已掌握不计）、平时作业 1（q2）。
      // 英语：总数 2（q4/q8）；试卷 2、平时作业 0 道不出现。
      // 政治：总数 0，文件夹全 0 道不出现。
      expect(
        find.descendant(
          of: bookBox('数学'),
          matching: find.text('共 3 道 · 试卷 2 道 · 平时作业 1 道'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: bookBox('英语'),
          matching: find.text('共 2 道 · 试卷 2 道'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: bookBox('政治'),
          matching: find.text('共 0 道'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('封面总数排除已掌握：总数等于所显示文件夹数之和', (tester) async {
      await pumpWrongbook(tester);
      await openShelfFromList(tester);
      // 分布行里的数加起来对得上：数学 3 = 试卷 2 + 平时作业 1
      //（q7 已掌握，两边都不计）；英语 2 = 试卷 2；政治 0。
      List<int> numbers(String name) {
        final data = tester
            .widget<Text>(
              find.descendant(
                of: bookBox(name),
                matching: find.byWidgetPredicate(
                  (w) => w is Text && (w.data ?? '').startsWith('共 '),
                ),
              ),
            )
            .data!;
        return RegExp(
          r'\d+',
        ).allMatches(data).map((m) => int.parse(m.group(0)!)).toList();
      }
      for (final name in ['数学', '英语', '政治']) {
        final nums = numbers(name);
        expect(
          nums.first,
          nums.skip(1).fold(0, (a, b) => a + b),
          reason: '$name 分布行总数应等于文件夹数之和',
        );
      }
    });

    testWidgets('书页边：右沿 8px、上下各 inset 4px', (tester) async {
      await pumpWrongbook(tester);
      await openShelfFromList(tester);
      final edge = find.byWidgetPredicate(
        (w) =>
            w is CustomPaint &&
            w.painter?.runtimeType.toString() == '_Book12PageEdgePainter',
      );
      expect(edge, findsNWidgets(3));
      for (var i = 0; i < 3; i++) {
        final edgeRect = tester.getRect(edge.at(i));
        final bookRect = tester.getRect(
          bookBox(['数学', '英语', '政治'][i]),
        );
        expect(edgeRect.right, moreOrLessEquals(bookRect.right, epsilon: 0.5));
        expect(edgeRect.width, 8);
        expect(edgeRect.top, moreOrLessEquals(bookRect.top + 4, epsilon: 0.5));
        expect(
          edgeRect.bottom,
          moreOrLessEquals(bookRect.bottom - 4, epsilon: 0.5),
        );
      }
    });

    testWidgets('开始复习按钮：白底、字色 cdd、13.5px、圆角 3', (tester) async {
      await pumpWrongbook(tester);
      await openShelfFromList(tester);
      const cdd = {
        '数学': Color(0xFF102F75),
        '英语': Color(0xFF044A33),
        '政治': Color(0xFF7C1F1B),
      };
      for (final entry in cdd.entries) {
        final button = find.descendant(
          of: bookBox(entry.key),
          matching: find.text('开始复习'),
        );
        expect(button, findsOneWidget);
        final text = tester.widget<Text>(button).style!;
        expect(text.fontSize, 13.5);
        expect(text.fontWeight, FontWeight.w700);
        expect(text.letterSpacing, 2.97);
        expect(text.color, entry.value);
        // 按钮底是书内白底圆角 3 的容器。
        final container = find.descendant(
          of: bookBox(entry.key),
          matching: find.byWidgetPredicate(
            (w) =>
                w is Container &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).color == Colors.white,
          ),
        );
        expect(container, findsOneWidget);
        final decoration =
            (tester.widget<Container>(container).decoration as BoxDecoration);
        expect(decoration.borderRadius, BorderRadius.circular(3));
      }
    });

    testWidgets('未知学科回退：有存好的英文名按存值大写显示', (tester) async {
      final repo = threeSubjectRepo();
      repo.subjectsValue = [
        ...repo.subjectsValue,
        Subject(
          id: 'biology',
          // 学科名 38px 时一行只放得下约 3 个拉丁字母（测试字体 Ahem 下
          // 每字占满 1em）；用 3 字母名，免得名字换行把上半区撑爆。
          name: 'Bio',
          color: const Color(0xFF7C3AED),
          icon: '生',
          coverColor: 'purple',
          // D-257：英文行读存好的 englishName（GLM 翻译或手动填），
          // 渲染时统一大写；旧口径“大写学科名回退”已作废。
          englishName: 'Bio',
        ),
      ];
      repo.questions = [
        ...repo.questions,
        wbq('q10', '细胞结构', subjectId: 'biology'),
      ];
      await pumpWrongbook(tester, repo: repo);
      await openShelfFromList(tester);
      expect(find.text('BIO'), findsOneWidget);
      final container = tester.widget<AnimatedContainer>(bookBox('Bio'));
      final gradient =
          (container.decoration as BoxDecoration).gradient as LinearGradient;
      expect(gradient.colors.first, const Color(0xFF7C3AED));
      // cd 比学科色暗（明度更低）。
      final base = HSLColor.fromColor(const Color(0xFF7C3AED)).lightness;
      expect(
        HSLColor.fromColor(gradient.colors[1]).lightness,
        lessThan(base),
      );
    });

    testWidgets('D-257：没有英文名的学科不画英文行；有存值时按存值大写', (
      tester,
    ) async {
      final repo = threeSubjectRepo();
      repo.subjectsValue = [
        ...repo.subjectsValue,
        // 化学：没有 englishName（翻译失败/无 key 的回退）。
        Subject(
          id: 'chemistry',
          name: '化学',
          color: const Color(0xFF0891B2),
          icon: '化',
          coverColor: 'blue',
        ),
        // 生物：存了小写英文名，渲染时统一大写。
        Subject(
          id: 'biology',
          name: '生物',
          color: const Color(0xFF7C3AED),
          icon: '生',
          coverColor: 'purple',
          englishName: 'Biology',
        ),
      ];
      repo.questions = [
        ...repo.questions,
        wbq('q10', '细胞结构', subjectId: 'biology'),
      ];
      await pumpWrongbook(tester, repo: repo);
      await openShelfFromList(tester);
      expect(find.text('化学'), findsOneWidget);
      expect(find.text('CHEMISTRY'), findsNothing);
      expect(find.text('BIOLOGY'), findsOneWidget);
    });
  });
}
