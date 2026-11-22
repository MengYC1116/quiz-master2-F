// 二十一批（D-241/D-242/D-243）：内容搜索、框内 kbd 去掉、
// 导出入口「导出打印」进结果头。
// 复用 wrongbook_page_test.dart 的 pumpWrongbook /
// FakeWrongbookRepo（同仓惯例）。
//
// 模拟题规则（Meng 2026-11-22 09:23）：模拟题/演示题必须是他给的
// 图片或他谷歌硬盘里的，不许自编题目内容、标题、题干。本文件
// 只用演示库 9 道真题：liveDemoRepo() 的标题/题干/答案/解析/
// 文件夹/标签/错因/知识点/试卷，逐字抄自 live 库
// （~/.local/share/quiz-master2/quiz-master2.db，2026-11-22
// 查得），一行也没编。createdAt 用相对日期（仅定列表顺序，
// 不是题目内容）。
//
// 两个覆盖缺口（真题里没有这类内容，编不出来，先留着）：
// 1. 选项搜索：live 库 v2 与 v1 备份都没有 option_contents 列，
//    demo_data.dart 的 demoQuestions() 也已删——9 道真题没有任何
//    一道存过选项文字，选项分支目前无真题测试覆盖。
// 2. 备注搜索：live 库 9 道题的 notes 全是空，备注分支同理。
// 如需补，让 Meng 给选项/备注文字再加。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';

import 'wrongbook_page_test.dart';

/// 演示库 9 道真题（逐字抄自 live 库，见文件头注释）。
/// 仅 5 道已整理（q-math-2、q-eng-2、q-pol-1、q-pol-3 未整理），
/// L1 列表只显示已整理的 5 道。
FakeWrongbookRepo liveDemoRepo() {
  final now = DateTime.now();
  Question q(
    String id,
    String title, {
    required String subjectId,
    required List<String> folderIds,
    required String examId,
    required List<String> knowledgePointIds,
    required List<String> errorTypes,
    required List<String> tags,
    required String sliceText,
    required String answer,
    required String explanation,
    required int daysAgo,
    required bool isOrganized,
  }) =>
      Question(
        id: id,
        title: title,
        subjectId: subjectId,
        folderIds: folderIds,
        examId: examId,
        knowledgePointIds: knowledgePointIds,
        errorTypes: errorTypes,
        tags: tags,
        sliceText: sliceText,
        answer: answer,
        explanation: explanation,
        createdAt: now.subtract(Duration(days: daysAgo)),
        isOrganized: isOrganized,
      );
  return FakeWrongbookRepo(
    questions: [
      q(
        'q-math-1',
        '函数极限',
        subjectId: 'math',
        folderIds: const ['folder-math-试卷'],
        examId: 'exam-math-mid',
        knowledgePointIds: const ['kp-math-limit'],
        errorTypes: const ['概念不清'],
        tags: const ['易错', '常考'],
        sliceText: '题：lim(x→0) sin 3x / x 的值是（　）',
        answer: '1',
        explanation: 'lim(x→0) sin3x/x = 3·lim sin3x/3x = 3。',
        daysAgo: 7,
        isOrganized: true,
      ),
      q(
        'q-math-2',
        '导数应用综合（整题含两问）',
        subjectId: 'math',
        folderIds: const ['folder-math-平时作业'],
        examId: 'exam-math-mid',
        knowledgePointIds: const ['kp-math-derivative'],
        errorTypes: const ['方法不会'],
        tags: const ['易错'],
        sliceText:
            '题：设 f(x) = x³ − 3x² + 2。\n（1）求 f(x) 的单调区间与极值；\n（2）求曲线 y = f(x) 在点 (1, 0) 处的切线方程。',
        answer: '见解析',
        explanation: '（1）单调增区间与极值由 f′(x)=0 求得；（2）切线方程 y=…。',
        daysAgo: 4,
        isOrganized: false,
      ),
      q(
        'q-math-3',
        '定积分阴影面积',
        subjectId: 'math',
        folderIds: const ['folder-math-模拟卷'],
        examId: 'exam-math-mid',
        knowledgePointIds: const ['kp-math-integral'],
        errorTypes: const ['计算错误'],
        tags: const ['需重做'],
        sliceText: '题：下图阴影部分由曲线 y = x² 与直线 y = 1 围成。用定积分表示阴影部分的面积，并计算其值。',
        answer: '见解析',
        explanation: '阴影面积 = ∫(1 − x²)dx（定积分表示）。',
        daysAgo: 2,
        isOrganized: true,
      ),
      q(
        'q-eng-1',
        '学术词汇辨析',
        subjectId: 'english',
        folderIds: const ['folder-english-平时作业'],
        examId: 'exam-eng-mid',
        knowledgePointIds: const ['kp-eng-vocab'],
        errorTypes: const ['概念不清'],
        tags: const ['易错', '常考'],
        sliceText: '题：The new evidence ______ the original hypothesis, forcing the team to revise the whole model.',
        answer: '见解析',
        explanation: 'the new evidence ______ the original hypothesis：根据语境选动词。',
        daysAgo: 6,
        isOrganized: true,
      ),
      q(
        'q-eng-2',
        '长篇阅读（节选）',
        subjectId: 'english',
        folderIds: const ['folder-english-试卷'],
        examId: 'exam-eng-mid',
        knowledgePointIds: const ['kp-eng-reading'],
        errorTypes: const ['审题失误'],
        tags: const ['常考'],
        sliceText:
            '题：Passage: Universities are rethinking the lecture …（节选）\nQuestions 1–3: 主旨题 / 细节题 / 推理题，共 3 问。',
        answer: '见解析',
        explanation: 'Questions 1–3：主旨题 / 细节题 / 推理题，共 3 问。',
        daysAgo: 3,
        isOrganized: false,
      ),
      q(
        'q-eng-3',
        '图表作文',
        subjectId: 'english',
        folderIds: const ['folder-english-模拟卷'],
        examId: 'exam-eng-mid',
        knowledgePointIds: const ['kp-eng-writing'],
        errorTypes: const ['方法不会'],
        tags: const ['需重做'],
        sliceText:
            '题：Figure 1 · Students’ monthly spending (demo chart)\nFood / Books / Trans / Clothes',
        answer: '见解析',
        explanation: 'Figure 1 · Students’ monthly spending：描述图表并分析。',
        daysAgo: 1,
        isOrganized: true,
      ),
      q(
        'q-pol-1',
        '史纲时间轴图题（带图题）',
        subjectId: 'politics',
        folderIds: const ['folder-politics-试卷'],
        examId: 'exam-pol-mid',
        knowledgePointIds: const ['kp-pol-history'],
        errorTypes: const ['审题失误'],
        tags: const ['易错'],
        sliceText:
            '题：读图：时间轴标出 1921、1949、1978、2012 四个年份。与 1978 年对应的重大历史事件是什么？它有何历史意义？\n图 1 · 历史时间轴',
        answer: '见解析',
        explanation: '与 1978 年对应的重大历史事件及其历史意义。',
        daysAgo: 5,
        isOrganized: false,
      ),
      q(
        'q-pol-2',
        '马原',
        subjectId: 'politics',
        folderIds: const ['folder-politics-平时作业'],
        examId: 'exam-pol-mid',
        knowledgePointIds: const ['kp-pol-marx'],
        errorTypes: const ['概念不清'],
        tags: const ['常考'],
        sliceText: '题：运用矛盾普遍性与特殊性的关系，说明如何推进中国式现代化。',
        answer: '见解析',
        explanation: '矛盾普遍性与特殊性的关系。',
        daysAgo: 2,
        isOrganized: true,
      ),
      q(
        'q-pol-3',
        '材料分析：中国式现代化（整题含两问）',
        subjectId: 'politics',
        folderIds: const ['folder-politics-模拟卷'],
        examId: 'exam-pol-mid',
        knowledgePointIds: const ['kp-pol-marx'],
        errorTypes: const ['方法不会'],
        tags: const ['易错'],
        sliceText:
            '题：材料：中国式现代化是中国共产党领导的社会主义现代化，既有各国现代化的共同特征，更有基于自己国情的中国特色。（节选）\n（1）中国式现代化有哪些中国特色？\n（2）运用矛盾普遍性与特殊性的关系，说明应如何推进中国式现代化。',
        answer: '见解析',
        explanation: '（1）中国式现代化的中国特色；（2）普遍性与特殊性的关系。',
        daysAgo: 2,
        isOrganized: false,
      ),
    ],
    folderList: const [
      Folder(id: 'folder-math-试卷', name: '试卷', subjectId: 'math', sortOrder: 0),
      Folder(id: 'folder-math-平时作业', name: '平时作业', subjectId: 'math', sortOrder: 1),
      Folder(id: 'folder-math-模拟卷', name: '模拟卷', subjectId: 'math', sortOrder: 2),
      Folder(id: 'folder-english-试卷', name: '试卷', subjectId: 'english', sortOrder: 0),
      Folder(id: 'folder-english-平时作业', name: '平时作业', subjectId: 'english', sortOrder: 1),
      Folder(id: 'folder-english-模拟卷', name: '模拟卷', subjectId: 'english', sortOrder: 2),
      Folder(id: 'folder-politics-试卷', name: '试卷', subjectId: 'politics', sortOrder: 0),
      Folder(id: 'folder-politics-平时作业', name: '平时作业', subjectId: 'politics', sortOrder: 1),
      Folder(id: 'folder-politics-模拟卷', name: '模拟卷', subjectId: 'politics', sortOrder: 2),
    ],
    examList: [
      Exam(id: 'exam-math-mid', name: '高等数学期中试卷', date: DateTime(2026, 11, 3)),
      Exam(id: 'exam-eng-mid', name: '大学英语期中试卷', date: DateTime(2026, 11, 4)),
      Exam(id: 'exam-pol-mid', name: '大学思政期中试卷', date: DateTime(2026, 11, 5)),
    ],
    kpList: const [
      KnowledgePoint(id: 'kp-math-limit', subjectId: 'math', chapter: '函数与极限', name: '函数极限'),
      KnowledgePoint(id: 'kp-math-derivative', subjectId: 'math', chapter: '导数与微分', name: '导数应用'),
      KnowledgePoint(id: 'kp-math-integral', subjectId: 'math', chapter: '定积分', name: '定积分应用'),
      KnowledgePoint(id: 'kp-eng-vocab', subjectId: 'english', chapter: '词汇', name: '学术词汇'),
      KnowledgePoint(id: 'kp-eng-reading', subjectId: 'english', chapter: '阅读', name: '长篇阅读'),
      KnowledgePoint(id: 'kp-eng-writing', subjectId: 'english', chapter: '写作', name: '图表作文'),
      KnowledgePoint(id: 'kp-pol-history', subjectId: 'politics', chapter: '史纲', name: '时间轴'),
      KnowledgePoint(id: 'kp-pol-marx', subjectId: 'politics', chapter: '马原', name: '矛盾观'),
    ],
    tagList: const ['易错', '常考', '需重做'],
  );
}

/// L1 行显示文字（D-244 修订：行标题是完整题干，空白折叠后显示）。
/// 用字面显示文字找行，不走 boardRow（标题→显示文字映射在
/// wrongbook_page_test.dart，只覆盖三科测试库）。
Finder demoRow(String display) =>
    find.textContaining(display, findRichText: true);

Future<void> typeSearch(WidgetTester tester, String text) async {
  await tester.enterText(
    find.byKey(const ValueKey('big-search')),
    text,
  );
  await tester.pump();
}

void main() {
  group('二十一批：内容搜索（D-241，真题库）', () {
    testWidgets('题干命中：搜“阴影”只出定积分阴影面积', (tester) async {
      await pumpWrongbook(tester, repo: liveDemoRepo());
      await typeSearch(tester, '阴影');
      // “阴影”只在 q-math-3 的题干/解析里（元数据里没有）。
      expect(demoRow('题：下图阴影部分由曲线 y = x² 与直线 y = 1 围成。用定积分表示阴影部分的面积，并计算其值。'), findsOneWidget);
      expect(demoRow('题：lim(x→0) sin 3x / x 的值是（ ）'), findsNothing);
      expect(demoRow('题：The new evidence ______ the original hypothesis, forcing the team to revise the whole model.'), findsNothing);
    });

    testWidgets('解析命中：搜“sin3x”只出函数极限（题干里是 sin 3x，带空格）', (tester) async {
      await pumpWrongbook(tester, repo: liveDemoRepo());
      await typeSearch(tester, 'sin3x');
      // “sin3x”（无空格）只在 q-math-1 的解析里，题干是 “sin 3x”。
      expect(demoRow('题：lim(x→0) sin 3x / x 的值是（ ）'), findsOneWidget);
      expect(demoRow('题：下图阴影部分由曲线 y = x² 与直线 y = 1 围成。用定积分表示阴影部分的面积，并计算其值。'), findsNothing);
      expect(demoRow('题：The new evidence ______ the original hypothesis, forcing the team to revise the whole model.'), findsNothing);
    });

    testWidgets('答案命中：搜“见解析”出 4 道已整理的题，函数极限（答案是 1）不出', (tester) async {
      await pumpWrongbook(tester, repo: liveDemoRepo());
      await typeSearch(tester, '见解析');
      expect(demoRow('题：下图阴影部分由曲线 y = x² 与直线 y = 1 围成。用定积分表示阴影部分的面积，并计算其值。'), findsOneWidget);
      expect(demoRow('题：The new evidence ______ the original hypothesis, forcing the team to revise the whole model.'), findsOneWidget);
      expect(demoRow('题：Figure 1 · Students’ monthly spending (demo chart) Food / Books / Trans / Clothes'), findsOneWidget);
      expect(demoRow('题：运用矛盾普遍性与特殊性的关系，说明如何推进中国式现代化。'), findsOneWidget);
      expect(demoRow('题：lim(x→0) sin 3x / x 的值是（ ）'), findsNothing);
    });

    testWidgets('元数据仍命中：搜标签“常考”出函数极限/学术词汇辨析/马原', (tester) async {
      await pumpWrongbook(tester, repo: liveDemoRepo());
      await typeSearch(tester, '常考');
      expect(demoRow('题：lim(x→0) sin 3x / x 的值是（ ）'), findsOneWidget);
      expect(demoRow('题：The new evidence ______ the original hypothesis, forcing the team to revise the whole model.'), findsOneWidget);
      expect(demoRow('题：运用矛盾普遍性与特殊性的关系，说明如何推进中国式现代化。'), findsOneWidget);
      expect(demoRow('题：下图阴影部分由曲线 y = x² 与直线 y = 1 围成。用定积分表示阴影部分的面积，并计算其值。'), findsNothing);
      expect(demoRow('题：Figure 1 · Students’ monthly spending (demo chart) Food / Books / Trans / Clothes'), findsNothing);
    });
  });

  group('二十一批：导出打印进结果头（D-243）', () {
    testWidgets('结果头里有「导出打印」chip，点进模式后 chip 消失', (tester) async {
      await pumpWrongbook(tester);
      expect(find.text('导出打印'), findsOneWidget);
      expect(find.text('▣ 预览导出模式'), findsNothing);
      expect(find.byKey(const Key('export-selected-toolbar')), findsOneWidget);
      await tester.tap(find.byKey(const Key('export-selected-toolbar')));
      await tester.pump();
      expect(find.byKey(const Key('export-mode-cancel')), findsOneWidget);
      expect(find.byKey(const Key('export-mode-hint')), findsOneWidget);
      // 模式里入口 chip 不画（取消/导出（n）在下方控制区）。
      expect(find.text('导出打印'), findsNothing);
    });
  });

  group('二十一批：范围说明行（D-241/D-242）', () {
    testWidgets('范围说明行写明内容搜索范围，旧“只搜元数据”全站消失', (tester) async {
      await pumpWrongbook(tester);
      expect(
        find.textContaining('可搜标题、题干、选项、答案、解析、备注'),
        findsOneWidget,
      );
      expect(find.textContaining('只搜元数据'), findsNothing);
    });
  });
}
