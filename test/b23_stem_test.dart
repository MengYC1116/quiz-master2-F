// 二十三批第 2 件（D-251）：列表行标题与内容搜索走统一题干口径 displayStem。
//
// 纯函数层：displayStem / rowDisplayTitle / searchHaystack，输入是合成字符串
//（字符串格式化函数的输入，不算模拟题；Question 只作承载容器，标题用占位字符串）。
// widget 层：演示库题干内容填进 ocrStem（sliceText 清空），行标题显示 OCR 题干。
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/wrongbook/wrongbook_page.dart';
import 'package:quiz_master2/state/wrongbook_notifier.dart';

import 'b21_content_search_test.dart';
import 'wrongbook_page_test.dart';

/// 格式化探针用的最小 Question：只承载 sliceText / ocrStem 与回退标题。
Question _probe({
  String title = '文件名标题',
  String sliceText = '',
  String? ocrStem,
}) => Question(
  id: 'stem-probe',
  title: title,
  subjectId: 'math',
  sliceText: sliceText,
  ocrStem: ocrStem,
  createdAt: DateTime(2026, 11, 22),
);

void main() {
  group('二十三批：displayStem 统一题干口径（D-251，纯函数）', () {
    test('ocrStem 优先于 sliceText', () {
      final q = _probe(sliceText: '题：旧占位题干', ocrStem: '题：OCR 识别出的题干');
      expect(q.displayStem, '题：OCR 识别出的题干');
      expect(rowDisplayTitle(q), '题：OCR 识别出的题干');
    });

    test('ocrStem 只有空白时回退 sliceText', () {
      final q = _probe(sliceText: '题：旧占位题干', ocrStem: '   ');
      expect(q.displayStem, '题：旧占位题干');
    });

    test('无 ocrStem 时回退 sliceText，演示题行为不变', () {
      final q = _probe(sliceText: '题：旧占位题干');
      expect(q.displayStem, '题：旧占位题干');
      expect(rowDisplayTitle(q), '题：旧占位题干');
    });

    test('两字段都空时行标题回退文件名标题', () {
      final q = _probe();
      expect(q.displayStem, '');
      expect(rowDisplayTitle(q), '文件名标题');
    });

    test('ocrStem 里的 LaTeX 同样去掉', () {
      final q = _probe(ocrStem: r'题：求 $x^2$ 的导数');
      expect(rowDisplayTitle(q), '题：求 的导数');
    });

    test('searchHaystack 含 ocrStem：搜 OCR 题干命中', () {
      final q = _probe(sliceText: '', ocrStem: '题：OCR 题干里的生僻词');
      final st = WrongbookState(
        subjects: [Subject.math],
        questions: [q],
      );
      expect(st.searchHaystack(q), contains('ocr 题干里的生僻词'));
    });

    test('D-258 searchHaystack 不含英文名：搜英文名不命中，搜中文名命中', () {
      final q = Question(
        id: 'stem-probe-en',
        title: '文件名标题',
        subjectId: 'chem',
        sliceText: '题：唯一词',
        createdAt: DateTime(2026, 11, 22),
      );
      final st = WrongbookState(
        subjects: [
          Subject(
            id: 'chem',
            name: '化学',
            color: const Color(0xFF7C3AED),
            icon: '化',
            englishName: 'Chemistry',
          ),
        ],
        questions: [q],
      );
      final hay = st.searchHaystack(q);
      expect(hay, isNot(contains('Chemistry')));
      expect(hay, isNot(contains('CHEMISTRY')));
      expect(hay, contains('化学'));
    });

    test('searchHaystack 不重复：无 ocrStem 时 sliceText 只出现一次', () {
      final q = _probe(sliceText: '题：唯一词');
      final st = WrongbookState(
        subjects: [Subject.math],
        questions: [q],
      );
      final hay = st.searchHaystack(q);
      expect('唯一词'.allMatches(hay).length, 1);
    });
  });

  group('二十三批：行标题显示 OCR 题干（D-251，widget 层）', () {
    testWidgets('sliceText 为空、ocrStem 有题干的行显示 OCR 题干，不显示文件名', (tester) async {
      final repo = liveDemoRepo();
      final old = repo.questions.firstWhere((q) => q.id == 'q-math-1');
      repo.questions[repo.questions.indexOf(old)] = Question(
        id: old.id,
        title: old.title,
        subjectId: old.subjectId,
        folderIds: old.folderIds,
        examId: old.examId,
        knowledgePointIds: old.knowledgePointIds,
        errorTypes: old.errorTypes,
        tags: old.tags,
        sliceText: '',
        // 题干文字逐字抄自该题在演示库里的 sliceText（只换字段，不编新题干）。
        ocrStem: '题：lim(x→0) sin 3x / x 的值是（　）',
        answer: old.answer,
        explanation: old.explanation,
        createdAt: old.createdAt,
        isOrganized: true,
      );
      await pumpWrongbook(tester, repo: repo);
      await openMathList(tester);
      // 行标题是 OCR 题干（全角空格经 rowDisplayTitle 折叠成半角）。
      expect(demoRow('题：lim(x→0) sin 3x / x 的值是（ ）'), findsOneWidget);
      expect(find.text('函数极限'), findsNothing);
    });
  });
}
