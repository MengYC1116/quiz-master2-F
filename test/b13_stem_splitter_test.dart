// M4（十三批）：题干切分器单元测试（纯逻辑，不碰库、不碰网络）。
//
// 真实输入：glm-compare 里 6 道题的 .md 文本原文照录
//（~/workspace/batch13-work/glm-compare/*-glm-ocr.jsonl.md），
// 期望题干以 glm-vs-vl16-compare.md 的结论为准。
// 边界用例：每条失败都要能说出是哪条规则没守住——测试名即规则名，
// 不为过测试放宽规则。
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/services/stem_splitter.dart';

// ---------------------------------------------------------------------------
// 真实输入（照录，未改一字）
// ---------------------------------------------------------------------------

// single01-q2（glm-compare/single01-q2-glm-ocr.jsonl.md 原文照录）
const single01Q2 = r'''2. 双曲线 $ 4 x^{2}-y^{2}=4 $的离心率为

A. $ \sqrt{3} $ B. 2 C. $ \frac{\sqrt{5}}{2} $ D. $ \sqrt{5} $''';

// single01-q4（glm-compare/single01-q4-glm-ocr.jsonl.md 原文照录）
const single01Q4 = r'''4. 若 $ \cos(\alpha+\frac{\pi}{4})=\frac{3}{5}, $ $ \alpha\in(0,\frac{\pi}{2}) $ ，则 $ \sin\alpha= $

A. $ \frac{\sqrt{2}}{10} $ B. $ \frac{3\sqrt{2}}{10} $ C. $ \frac{\sqrt{2}}{5} $ D. $ \frac{3\sqrt{2}}{5} $''';

// double01-q1（glm-compare/double01-q1-glm-ocr.jsonl.md 原文照录）
const double01Q1 = r'''听第6段材料，回答第6、7题。

6. Why does the man call the woman?

A. To cancel his training. B. To arrange his operation. C. To make an appointment.

7. What is the matter with the man?

A. He has a bad cold. B. He has got an injury. C. He has a high temperature.''';

// double01-q5（glm-compare/double01-q5-glm-ocr.jsonl.md 原文照录）
const double01Q5 = r'''1. What will the man probably do for the woman?

A. Repair her shoes. B. Give back her money. C. Exchange her shoes.''';

// triple01-q3（glm-compare/triple01-q3-glm-ocr.jsonl.md 原文照录）
const triple01Q3 = r'''1. 化简 $ \frac{2+4 \mathrm{i}}{(1+\mathrm{i})^{2}} $的结果是 (    )

(A) $ 2+\mathrm{i} $ (B) $ - 2+\mathrm{i} $ (C) $ 2-\mathrm{i} $ (D) $ - 2-\mathrm{i} $''';

// triple01-q4（glm-compare/triple01-q4-glm-ocr.jsonl.md 原文照录）
const triple01Q4 = r'''9. 设椭圆 $ \frac{x^{2}}{a^{2}}+\frac{y^{2}}{b^{2}}=1 $ （ $ a>b>0 $ ）的离心率为 $ e=\frac{1}{2} $ ，右焦点为 F(c,0)，方程 $ ax^{2}+bx-c=0 $ 的两个实根分别为 $ x_{1} $和 $ x_{2} $ ，则点 P $ ( x_{1},x_{2} ) $ （    )

(A) 必在圆 $ x^{2}+y^{2}=2 $ 内 (B) 必在圆 $ x^{2}+y^{2}=2 $ 上

(C) 必在圆 $ x^{2}+y^{2}=2 $ 外 (D) 以上三种情形都有可能''';

void main() {
  group('真实输入：glm-compare 6 道题', () {
    test('single01-q2 双曲线：A. 行切分，题干保留题号 2.', () {
      final r = splitStem(single01Q2);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(
        r.stemText,
        r'2. 双曲线 $ 4 x^{2}-y^{2}=4 $的离心率为',
      );
      expect(r.cutIndex, isNotNull);
      expect(single01Q2.substring(r.cutIndex!), startsWith('A.'));
      expect(r.reason, isNotEmpty);
    });

    test('single01-q4 cos/sin：A. 行切分，题干保留题号 4.', () {
      final r = splitStem(single01Q4);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(
        r.stemText,
        r'4. 若 $ \cos(\alpha+\frac{\pi}{4})=\frac{3}{5}, $ $ \alpha\in(0,\frac{\pi}{2}) $ ，则 $ \sin\alpha= $',
      );
      expect(r.cutIndex, isNotNull);
      expect(single01Q4.substring(r.cutIndex!), startsWith('A.'));
    });

    test('double01-q1 一框两题（Q6+Q7）：两个候选切分点 → 存在歧义，不选第一个',
        () {
      // 一框含两道题不在 OCR 层处理（GPT 评审 §1.1）。两个 A 都可信，
      // 按规则标歧义、整段保留，一句不丢，等上游拆框或人工处理。
      final r = splitStem(double01Q1);
      expect(r.status, StemSplitStatus.ambiguous);
      expect(r.cutIndex, isNull);
      expect(r.stemText, double01Q1);
      expect(r.reason, contains('2 个候选切分点'));
    });

    test('double01-q5 英语听力 Q1：只有 A、B、C，没有 D 也切', () {
      final r = splitStem(double01Q5);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.stemText, '1. What will the man probably do for the woman?');
      expect(r.cutIndex, isNotNull);
      expect(double01Q5.substring(r.cutIndex!), startsWith('A.'));
    });

    test('triple01-q3 复数：(A) 括号式切分，题干里的 (    ) 空格不误切', () {
      final r = splitStem(triple01Q3);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(
        r.stemText,
        r'1. 化简 $ \frac{2+4 \mathrm{i}}{(1+\mathrm{i})^{2}} $的结果是 (    )',
      );
      expect(r.cutIndex, isNotNull);
      expect(triple01Q3.substring(r.cutIndex!), startsWith('(A)'));
    });

    test('triple01-q4 椭圆：(A) 括号式切分，选项跨行、C/D 在下一行', () {
      final r = splitStem(triple01Q4);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(
        r.stemText,
        r'9. 设椭圆 $ \frac{x^{2}}{a^{2}}+\frac{y^{2}}{b^{2}}=1 $ （ $ a>b>0 $ ）的离心率为 $ e=\frac{1}{2} $ ，右焦点为 F(c,0)，方程 $ ax^{2}+bx-c=0 $ 的两个实根分别为 $ x_{1} $和 $ x_{2} $ ，则点 P $ ( x_{1},x_{2} ) $ （    )',
      );
      expect(r.cutIndex, isNotNull);
      expect(triple01Q4.substring(r.cutIndex!), startsWith('(A)'));
    });

    test('真实输入的 reason 都不为空，且切分器永不产出“人工调整”', () {
      for (final input in [
        single01Q2,
        single01Q4,
        double01Q1,
        double01Q5,
        triple01Q3,
        triple01Q4,
      ]) {
        final r = splitStem(input);
        expect(r.reason, isNotEmpty);
        expect(r.status, isNot(StemSplitStatus.manuallyAdjusted));
      }
    });
  });

  group('边界：只出现 A 不切', () {
    test('只有 A、没有 B：不切分', () {
      const input = '3. 下列说法正确的是\n\nA. 第一项内容';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.notSplit);
      expect(r.cutIndex, isNull);
      expect(r.stemText, input);
      expect(r.reason, contains('未见 B'));
    });

    test('英语题干里的 "A. student..." 句子：只有 A、没有 B，不切分', () {
      const input =
          'Read the passage.\n\nA. student who studies hard will succeed in the exam.';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.notSplit);
      expect(r.stemText, input);
    });

    test('A. B. C. 连排标记：B 的“内容”是 C 标记，不算有内容，不切分', () {
      const input = 'A. B. C. D. 四点共线，求证四点共圆。';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.notSplit);
      expect(r.stemText, input);
    });
  });

  group('边界：A、B 足够，C、D 不是必要条件', () {
    test('只有 A、B，没有 C、D：切分', () {
      const input = '5. 下列正确的是\n\nA. 第一项 B. 第二项';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.stemText, '5. 下列正确的是');
      expect(input.substring(r.cutIndex!), startsWith('A.'));
    });

    test('医学 5 选项 A–E：切分', () {
      const input = '15. 下列正确的是\n\nA. 第一项 B. 第二项 C. 第三项 D. 第四项 E. 第五项';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.stemText, '15. 下列正确的是');
    });
  });

  group('边界：没选项标记，整段当题干', () {
    test('填空题：无标记，不切分', () {
      const input = r'6. 计算 $ \int_0^1 x dx = $ _______.';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.notSplit);
      expect(r.stemText, input);
    });

    test('解答题（证明题）：无标记，不切分', () {
      const input = r'7. 证明：若 $ a > b $，则 $ a^2 > b^2 $。';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.notSplit);
      expect(r.stemText, input);
    });

    test('名词解释：无标记，不切分', () {
      const input = '8. 解释“边际效用递减规律”。';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.notSplit);
      expect(r.stemText, input);
    });

    test('开头题号不盲删：无选项的题保留 "1."', () {
      const input = r'1. 已知函数 $ f(x) = x^2 $，求 $ f(1) $。';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.notSplit);
      expect(r.stemText, startsWith('1. '));
    });

    test('空文本与纯空白：未切分，题干为空', () {
      expect(splitStem('').status, StemSplitStatus.notSplit);
      expect(splitStem('').stemText, '');
      expect(splitStem('  \n\n  ').status, StemSplitStatus.notSplit);
      expect(splitStem('  \n\n  ').stemText, '');
    });
  });

  group('边界：题干里的 A 不是选项', () {
    test('“集合 A，且 A. B 分别表示……”：行文中单空格后的 A. 不算候选', () {
      const input = '已知集合 A，且 A. B 分别表示两个集合，则 A∪B 的元素个数是';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.notSplit);
      expect(r.stemText, input);
    });

    test('A、B 句子相隔数段：B 离 A 过远，不切分', () {
      const input = '第一段。\n\nA. student who studies hard will succeed.\n\n'
          '第二段很长很长，讲了很多别的内容。\n\n'
          'B. teacher who works hard will be respected.';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.notSplit);
      expect(r.stemText, input);
    });

    test('一框两题（合成）：两个可信 A → 存在歧义', () {
      const input = '1. 第一题题干\n\nA. 选项一 B. 选项二\n\n'
          '2. 第二题题干\n\nA. 选项三 B. 选项四';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.ambiguous);
      expect(r.cutIndex, isNull);
      expect(r.stemText, input);
    });
  });

  group('边界：标记格式', () {
    test('全角字母 + 全角句点 Ａ．Ｂ．Ｃ．：切分', () {
      const input = '9. 下列正确的是\n\nＡ． 第一项 Ｂ． 第二项 Ｃ． 第三项';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.stemText, '9. 下列正确的是');
      expect(input.substring(r.cutIndex!), startsWith('Ａ．'));
    });

    test('全角括号 （Ａ）（Ｂ）：切分', () {
      const input = '9. 下列正确的是\n\n（Ａ） 第一项 （Ｂ） 第二项';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.stemText, '9. 下列正确的是');
    });

    test('A) 风格：一行一个，切分', () {
      const input = '10. 下列正确的是\n\nA) 第一项\nB) 第二项\nC) 第三项';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.stemText, '10. 下列正确的是');
      expect(input.substring(r.cutIndex!), startsWith('A)'));
    });

    test('A、顿号风格：切分', () {
      const input = '10. 下列正确的是\n\nA、第一项\nB、第二项';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.stemText, '10. 下列正确的是');
    });

    test('A、B 格式不一致（A. 对 (B)）：不切分', () {
      const input = '13. 下列正确的是\n\nA. 第一项\n(B) 第二项';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.notSplit);
      expect(r.stemText, input);
      expect(r.reason, contains('格式不一致'));
    });

    test('B 标记后无实际选项内容：不切分', () {
      const input = '14. 下列正确的是\n\nA. 第一项\nB. ';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.notSplit);
      expect(r.stemText, input.trim());
    });
  });

  group('边界：同一行 / 小问 / 圈号', () {
    test('同一行两个选项 A. 第一项 B. 第二项：切分', () {
      const input = '下列说法正确的是（ ）\nA. 第一项 B. 第二项\nC. 第三项 D. 第四项';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.stemText, '下列说法正确的是（ ）');
    });

    test('同一行 A 与题干只隔一个空格：保守起见不切分', () {
      const input = '下列说法正确的是 A. 第一项 B. 第二项';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.notSplit);
      expect(r.stemText, input);
    });

    test('同一行 A 与题干隔开 ≥2 空格（栏位间隔）：切分', () {
      const input = '下列说法正确的是    A. 第一项 B. 第二项';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.stemText, '下列说法正确的是');
    });

    test('小问 (1)(2)：不参与切分', () {
      const input = '11. 已知函数 f(x) = x²。\n（1）求函数的定义域。\n（2）求函数的值域。';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.notSplit);
      expect(r.stemText, input);
    });

    test('小问 (1)(2) 半角括号：不参与切分', () {
      const input = '11. 已知函数 f(x) = x²。\n(1) 求定义域 (2) 求值域';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.notSplit);
      expect(r.stemText, input);
    });

    test('圈号 ①②③④：不参与切分', () {
      const input = '12. 下列说法正确的有 ①②③④\n① 第一种说法 ② 第二种说法';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.notSplit);
      expect(r.stemText, input);
    });
  });

  group('结果结构', () {
    test('自动切分时 cutIndex 指向 A 标记，stemText 与原文前缀一致', () {
      const input = '5. 下列正确的是\n\nA. 第一项 B. 第二项';
      final r = splitStem(input);
      expect(r.cutIndex, input.indexOf('A. 第一项'));
      expect(r.stemText, input.substring(0, r.cutIndex).trim());
    });

    test('状态枚举共 4 值，含 M5 用的“人工调整”', () {
      expect(StemSplitStatus.values.length, 4);
      expect(StemSplitStatus.manuallyAdjusted.label, '人工调整');
      expect(StemSplitStatus.notSplit.label, '未切分');
      expect(StemSplitStatus.autoSplit.label, '自动切分');
      expect(StemSplitStatus.ambiguous.label, '存在歧义');
    });
  });
}
