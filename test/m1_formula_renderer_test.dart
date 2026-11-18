// M1 十三批公式渲染器 POC：flutter_math_fork 0.7.4 覆盖率实测。
//
// 测试集来源（见 ~/workspace/batch13-work/M1-RENDERER-POC.md）：
// - G 组：6 道 GLM-OCR 真实输出里的全部公式（逐字取自
//   ~/workspace/batch13-work/glm-compare/*.jsonl.md）。
// - P 组：政治卷圈号 \textcircled{n}（pol-p01-glm-ocr.jsonl.md）。
// - T 组：GPT 评审类型表（§4.3）每一类的合成公式。
//
// 验收不只是“报不报错”：每条记录通过/失败，并检查尺寸、上标结构、
// 中文行内对齐、长公式溢出、失败回退。测试名只用编号，不含公式源码，
// 失败输出不泄露 LaTeX（LaTeX 只存在测试固件与内部数据里）。
//
// 运行（只跑本文件，不跑全量）：
// TMPDIR=$HOME/workspace/flutter-test-tmp \
// LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux \
// flutter test --concurrency=1 test/m1_formula_renderer_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/modules/ocr/question_content.dart';
import 'package:quiz_master2/modules/ocr/question_content_renderer.dart';

/// 单条公式用例。`expectFail` 为 true 表示预期渲染失败（走回退）。
class _FormulaCase {
  const _FormulaCase(this.id, this.latex, this.category,
      {this.displayMode = false, this.expectFail = false});
  final String id;
  final String latex;
  final String category;
  final bool displayMode;
  final bool expectFail;
}

// ---- G 组：真实 GLM 输出（6 道题里的全部公式，逐字摘录）----
const _glmCases = <_FormulaCase>[
  _FormulaCase('G01', r'4x^{2}-y^{2}=4', '双曲线离心率'),
  _FormulaCase('G01r', r' 4 x^{2}-y^{2}=4 ', 'GLM 原样带空格'),
  _FormulaCase('G02', r'\sqrt{3}', '根式'),
  _FormulaCase('G03', r'\frac{\sqrt{5}}{2}', '分数+根式'),
  _FormulaCase('G04', r'\sqrt{5}', '根式'),
  _FormulaCase('G05', r'\cos(\alpha+\frac{\pi}{4})=\frac{3}{5},', '三角+分数'),
  _FormulaCase('G06', r'\alpha\in(0,\frac{\pi}{2})', '希腊字母+分数'),
  _FormulaCase('G07', r'\sin\alpha=', '三角'),
  _FormulaCase('G08', r'\frac{\sqrt{2}}{10}', '分数+根式'),
  _FormulaCase('G09', r'\frac{3\sqrt{2}}{10}', '分数+根式'),
  _FormulaCase('G10', r'\frac{\sqrt{2}}{5}', '分数+根式'),
  _FormulaCase('G11', r'\frac{3\sqrt{2}}{5}', '分数+根式'),
  _FormulaCase('G12', r'\frac{2+4 \mathrm{i}}{(1+\mathrm{i})^{2}}', '复数+mathrm'),
  _FormulaCase('G13', r'2+\mathrm{i}', 'mathrm'),
  _FormulaCase('G14', r'- 2+\mathrm{i}', 'mathrm'),
  _FormulaCase('G15', r'2-\mathrm{i}', 'mathrm'),
  _FormulaCase('G16', r'- 2-\mathrm{i}', 'mathrm'),
  _FormulaCase('G17', r'\frac{x^{2}}{a^{2}}+\frac{y^{2}}{b^{2}}=1', '椭圆方程'),
  _FormulaCase('G18', r'a>b>0', '不等号'),
  _FormulaCase('G19', r'e=\frac{1}{2}', '分数'),
  _FormulaCase('G20', r'ax^{2}+bx-c=0', '二次方程'),
  _FormulaCase('G21', r'x_{1}', '下标'),
  _FormulaCase('G22', r'x_{2}', '下标'),
  _FormulaCase('G23', r'( x_{1},x_{2} )', '下标+括号'),
  _FormulaCase('G24', r'x^{2}+y^{2}=2', '圆方程'),
];

// ---- P 组：政治卷圈号（预期：fork 直接渲染失败，必须走预处理）----
const _circledCases = <_FormulaCase>[
  _FormulaCase('P01', r'\textcircled{1}', '圈号单', expectFail: true),
  _FormulaCase('P02', r'\textcircled{1}\textcircled{3}', '圈号组合',
      expectFail: true),
];

// ---- T 组：GPT 评审类型表合成公式 ----
const _typeCases = <_FormulaCase>[
  _FormulaCase('T01', r'(a+b)^{2}=a^{2}+2ab+b^{2}', '基础运算'),
  _FormulaCase('T02', r'\frac{\frac{1}{2}+\frac{1}{3}}{\frac{1}{4}}', '复杂分式'),
  _FormulaCase('T03', r'\sqrt[3]{x^{2}+1}', '高次根'),
  _FormulaCase('T04', r'a_{i,j}^{n+1}', '组合上下标'),
  _FormulaCase('T05', r'\lim_{x \to 0} \frac{\sin x}{x}', '极限'),
  _FormulaCase('T06', r'\sum_{i=1}^{n} x_{i}', '求和'),
  _FormulaCase('T07', r'\int_{0}^{1} x^{2}\,dx', '积分'),
  _FormulaCase('T08', r'\int_{-\infty}^{\infty} e^{-x^{2}}\,dx', '无穷积分'),
  _FormulaCase('T09', r'\sin^{2}x+\cos^{2}x=1', '三角函数'),
  _FormulaCase('T10', r'\begin{matrix} a & b \\ c & d \end{matrix}', '矩阵'),
  _FormulaCase('T11', r'\begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix}', '圆括号矩阵'),
  _FormulaCase('T12', r'\begin{vmatrix} a & b \\ c & d \end{vmatrix}', '行列式'),
  _FormulaCase('T13', r'\begin{cases} x+y=1 \\ x-y=0 \end{cases}', 'cases'),
  _FormulaCase('T14',
      r'f(x)=\begin{cases} 1, & \text{当 } x>0 \\ 0, & \text{当 } x\le 0 \end{cases}',
      'cases+text中文'),
  _FormulaCase('T15', r'\text{已知 } x>0', 'text中文'),
  _FormulaCase('T16', r'\alpha+\beta=\gamma \Rightarrow x \le y \ne z',
      '希腊/箭头/不等号'),
  _FormulaCase('T17', r'A \subset B, A \cup B, A \cap C, x \in \mathbb{R}',
      '集合符号+mathbb'),
  _FormulaCase('T18', r'\frac{-b\pm\sqrt{b^{2}-4ac}}{2a}', '独立公式',
      displayMode: true),
  _FormulaCase('T19', r'\mathrm{d}x', 'mathrm'),
  _FormulaCase('T21', r'\frac{1}', '缺参数（预期失败）', expectFail: true),
  _FormulaCase('T22', r'\unknowncmd{x}', '未知命令（预期失败）',
      expectFail: true),
  _FormulaCase('T23', r'\binom{n}{k}', '二项式系数'),
  _FormulaCase('T24', r'\sqrt{x}+\sqrt{y}=\sqrt{x+y+2\sqrt{xy}}', '嵌套根式'),
];

/// 每条结果只记编号 + 通过/失败，不记公式源码。
final Map<String, String> _results = {};

Future<(bool, Size?)> _pumpFormula(
  WidgetTester tester,
  _FormulaCase c,
) async {
  var failed = false;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: Math.tex(
            c.latex,
            mathStyle:
                c.displayMode ? MathStyle.display : MathStyle.text,
            textStyle: const TextStyle(fontSize: 16),
            onErrorFallback: (_) {
              failed = true;
              return const SizedBox(key: Key('m1-fallback'));
            },
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  final error = tester.takeException();
  Size? size;
  final mathFinder = find.byType(Math);
  if (mathFinder.evaluate().isNotEmpty) {
    size = tester.getSize(mathFinder);
  }
  // 无异常、无回退、尺寸非零才算通过。
  final passed =
      error == null && !failed && size != null && size.width > 0 && size.height > 0;
  _results[c.id] = passed ? 'PASS' : 'FAIL';
  return (passed, size);
}

void main() {
  group('M1 fork 覆盖率：真实 GLM 公式', () {
    for (final c in _glmCases) {
      testWidgets('M1-G ${c.id}', (tester) async {
        final (passed, size) = await _pumpFormula(tester, c);
        expect(passed, isTrue, reason: 'GLM 真实公式应渲染通过，尺寸=$size');
      });
    }
  });

  group('M1 fork 覆盖率：政治圈号（预期失败，走预处理）', () {
    for (final c in _circledCases) {
      testWidgets('M1-P ${c.id}', (tester) async {
        final (passed, _) = await _pumpFormula(tester, c);
        expect(passed, isFalse, reason: 'fork 不支持圈号，应失败并走预处理');
        expect(find.byKey(const Key('m1-fallback')), findsOneWidget);
      });
    }
  });

  group('M1 fork 覆盖率：GPT 类型表', () {
    for (final c in _typeCases) {
      testWidgets('M1-T ${c.id}', (tester) async {
        final (passed, size) = await _pumpFormula(tester, c);
        if (c.expectFail) {
          expect(passed, isFalse, reason: '预期失败的用例应触发回退');
          expect(find.byKey(const Key('m1-fallback')), findsOneWidget);
        } else {
          expect(passed, isTrue, reason: '类型表公式应渲染通过，尺寸=$size');
        }
      });
    }
  });

  group('M1 圈号预处理（确定性转换，不做全量规范化）', () {
    test('M1-C1 单个与组合圈号转换', () {
      expect(preprocessCircledNumbers(r'$\textcircled{1}$题干'),
          r'$①$题干');
      expect(
          preprocessCircledNumbers(r'$\textcircled{1}\textcircled{3}$'),
          r'$①③$');
    });
    test('M1-C2 超出 1-20 的圈号保留原命令', () {
      expect(preprocessCircledNumbers(r'$\textcircled{21}$'),
          r'$\textcircled{21}$');
      expect(preprocessCircledNumbers(r'$\textcircled{0}$'),
          r'$\textcircled{0}$');
    });
    test('M1-C3 其余字符不动：不做 Unicode 全量规范化', () {
      expect(preprocessCircledNumbers('Ａ．全角与破折号——2026年'),
          'Ａ．全角与破折号——2026年');
      expect(preprocessCircledNumbers('普通数字 123 不动'),
          '普通数字 123 不动');
    });
    test('M1-C4 解析后圈号成为 TextBlock，不再进公式渲染', () {
      final blocks = parseQuestionContent(
          r'$\textcircled{1}$全面深化改革是推进中国式现代化的根本动力');
      expect(blocks.length, 1);
      expect(blocks.first, isA<TextBlock>());
      expect((blocks.first as TextBlock).text, startsWith('①'));
    });
  });

  group('M1 解析器', () {
    test('M1-S1 真实 GLM 题干切成 7 公式 + 文本', () {
      const stem =
          r'9. 设椭圆 $\frac{x^{2}}{a^{2}}+\frac{y^{2}}{b^{2}}=1$ （ $a>b>0$ ）的离心率为 $e=\frac{1}{2}$ ，右焦点为 F(c,0)，方程 $ax^{2}+bx-c=0$ 的两个实根分别为 $x_{1}$和 $x_{2}$ ，则点 P $( x_{1},x_{2} )$ （    )';
      final blocks = parseQuestionContent(stem);
      final formulas =
          blocks.whereType<FormulaBlock>().toList(growable: false);
      expect(formulas.length, 7);
      expect(formulas.every((f) => f.latex.isNotEmpty), isTrue);
      expect(blocks.first, isA<TextBlock>());
    });
    test(r'M1-S2 $$ 独立公式 + 空公式丢弃 + 未闭合 $ 当文本', () {
      final blocks =
          parseQuestionContent(r'解：$$x=1$$ 另 $ $ 未闭合 $abc');
      expect(blocks.whereType<FormulaBlock>().length, 1);
      expect(blocks.whereType<FormulaBlock>().first.displayMode, isTrue);
      expect(blocks.last, isA<TextBlock>());
    });
    test('M1-S3 代码围栏优先于公式定界符（D-105 CodeBlock）', () {
      const input = r'''程序如下：
```python
print("$x$")
```
结束''';
      final blocks = parseQuestionContent(input);
      expect(blocks.whereType<CodeBlock>().length, 1);
      expect(blocks.whereType<FormulaBlock>(), isEmpty);
      expect((blocks.whereType<CodeBlock>().first).language, 'python');
    });
    test('M1-S4 转义美元符不切公式', () {
      final blocks = parseQuestionContent(r'价格 \$5，另 $x$');
      expect(blocks.whereType<FormulaBlock>().length, 1);
      expect((blocks.first as TextBlock).text, contains(r'$5'));
    });
    test('M1-S5 公式内首尾空格去掉（GLM 带空格形式）', () {
      final blocks = parseQuestionContent(r'$ 4 x^{2}-y^{2}=4 $');
      expect(blocks.whereType<FormulaBlock>().first.latex,
          r'4 x^{2}-y^{2}=4');
    });
    test('M1-S6 纯圈号公式段还原成文本，混合内容仍走公式', () {
      final blocks =
          parseQuestionContent(r'$\textcircled{1}\textcircled{3}$ 选项');
      expect(blocks.first, isA<TextBlock>());
      expect((blocks.first as TextBlock).text, startsWith('①③'));
      final mixed = parseQuestionContent(r'$\textcircled{1} x$');
      expect(mixed.whereType<FormulaBlock>().length, 1);
    });
  });

  group('M1 渲染器骨架', () {
    testWidgets('M1-R1 真实题干渲染：7 公式无回退', (tester) async {
      const stem =
          r'9. 设椭圆 $\frac{x^{2}}{a^{2}}+\frac{y^{2}}{b^{2}}=1$ （ $a>b>0$ ）的离心率为 $e=\frac{1}{2}$ ，右焦点为 F(c,0)，方程 $ax^{2}+bx-c=0$ 的两个实根分别为 $x_{1}$和 $x_{2}$ ，则点 P $( x_{1},x_{2} )$ （    )';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: QuestionContentRenderer(
                blocks: parseQuestionContent(stem),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(Math), findsNWidgets(7));
      expect(find.byKey(const Key('m1-image-fallback')), findsNothing);
    });

    testWidgets('M1-R2 非法公式自动回退原图，不抛错、不泄漏源码',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuestionContentRenderer(
              blocks: const [FormulaBlock(r'\frac{1}')],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('m1-image-fallback')), findsOneWidget);
      // 报错文本与公式源码均不得出现在界面上。
      expect(find.textContaining('frac'), findsNothing);
      expect(find.textContaining('ParseException'), findsNothing);
    });

    testWidgets('M1-R3 回退回调只报成败', (tester) async {
      var notified = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuestionContentRenderer(
              blocks: const [FormulaBlock(r'\unknowncmd{x}')],
              onFormulaFallback: () => notified = true,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(notified, isTrue);
    });

    testWidgets('M1-R4 ImageFallbackBlock 与 CodeBlock 正常渲染',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuestionContentRenderer(
              blocks: const [
                ImageFallbackBlock(),
                CodeBlock('print("hi")', language: 'python'),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('m1-image-fallback')), findsOneWidget);
      expect(find.textContaining('print'), findsOneWidget);
    });
  });

  group('M1 显示正确性（结构量测）', () {
    testWidgets('M1-A1 中文行内公式对齐', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 16, color: Colors.black),
                children: [
                  const TextSpan(text: '中文'),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Math.tex(
                      r'\frac{1}{2}',
                      mathStyle: MathStyle.text,
                      textStyle: const TextStyle(fontSize: 16),
                    ),
                  ),
                  const TextSpan(text: '混排'),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      // 行内公式用 PlaceholderAlignment.middle：公式中心应与整行文本
      // 的垂直中心基本重合（偏差小于半行高 8px@16 号字）。
      final lineCenter = tester.getCenter(find.byType(RichText).first);
      final mathCenter = tester.getCenter(find.byType(Math));
      final dy = (lineCenter.dy - mathCenter.dy).abs();
      _results['A1-dy'] = '${dy.toStringAsFixed(2)}px';
      // 行内公式中心与中文中心偏差应小于半行高（8px@16号字）。
      expect(dy, lessThan(8.0));
    });

    testWidgets('M1-A2 上标抬高、下标正常', (tester) async {
      Future<Size> sizeOf(String latex) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: Math.tex(
                  latex,
                  mathStyle: MathStyle.text,
                  textStyle: const TextStyle(fontSize: 16),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        return tester.getSize(find.byType(Math));
      }

      final plain = await sizeOf('x');
      final sup = await sizeOf(r'x^{2}');
      final sub = await sizeOf(r'x_{1}');
      _results['A2-plain'] = '${plain.width}x${plain.height}';
      _results['A2-sup'] = '${sup.width}x${sup.height}';
      _results['A2-sub'] = '${sub.width}x${sub.height}';
      expect(sup.height, greaterThan(plain.height),
          reason: '上标应抬高整体高度');
      expect(sup.width, greaterThan(plain.width));
      expect(sub.width, greaterThan(plain.width));
    });

    testWidgets('M1-A3 长公式窄容器不溢出（横向滚动）', (tester) async {
      const longLatex =
          r'x^{2}+y^{2}+z^{2}+a^{2}+b^{2}+c^{2}+p^{2}+q^{2}+r^{2}+s^{2}+t^{2}+u^{2}=1';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              child: FormulaView(
                latex: longLatex,
                displayMode: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(find.byKey(const Key('m1-image-fallback')), findsNothing);
    });

    testWidgets('M1-A4 裸长公式窄容器行为（对照：不包滚动会怎样）',
        (tester) async {
      const longLatex =
          r'x^{2}+y^{2}+z^{2}+a^{2}+b^{2}+c^{2}+p^{2}+q^{2}+r^{2}+s^{2}+t^{2}+u^{2}=1';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              child: Math.tex(
                longLatex,
                mathStyle: MathStyle.display,
                textStyle: const TextStyle(fontSize: 16),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      // 只记录行为，不强断言：把结果记入汇总表供报告引用。
      final error = tester.takeException();
      _results['A4-bare-overflow-error'] = error == null ? 'none' : 'thrown';
    });
  });

  test('M1 汇总：逐条结果（只含编号，不含公式源码）', () {
    final ids = <String>[
      ..._glmCases.map((c) => c.id),
      ..._circledCases.map((c) => c.id),
      ..._typeCases.map((c) => c.id),
      'A1-dy',
      'A2-plain',
      'A2-sup',
      'A2-sub',
      'A4-bare-overflow-error',
    ];
    for (final id in ids) {
      // ignore: avoid_print
      print('M1-RESULT $id ${_results[id] ?? 'NOT-RUN'}');
    }
  });
}
