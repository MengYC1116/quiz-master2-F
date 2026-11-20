// WP-A #2（九项修复 REV5）：选择题自动定型回归测试。
//
// 覆盖定稿 FIX-DESIGN-9-ISSUES.md §2.4 全部用例 + R2-6 + S3-1/S3-2/S3-3 + U4-1。
// 先写失败测试，再写实现（TDD）。
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/modules/ocr/question_classifier.dart';
import 'package:quiz_master2/services/stem_splitter.dart';

/// splitStem 的题型判定（autoSplit 即选择题）。
String? _type(String md) => classifyQuestionText(md).questionType;

void main() {
  group('§2.4 同行选项与跨行选项', () {
    test('题干同行 A. 甲 B. 乙 C. 丙 D. 丁（单空格）→ autoSplit，choice_single', () {
      const input = '下列说法正确的是 A. 甲 B. 乙 C. 丙 D. 丁';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.stemText, '下列说法正确的是');
      expect(_type(input), 'choice_single');
    });

    test('长选项跨多行（A 选项折 3 行）→ autoSplit', () {
      const input = '下列说法正确的是\n'
          'A. 第一项内容很长很长\n'
          '续行第二行内容\n'
          '续行第三行内容\n'
          'B. 第二项\n'
          'C. 第三项\n'
          'D. 第四项';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.stemText, '下列说法正确的是');
      expect(_type(input), 'choice_single');
    });

    test('格式混杂 A. / B、 / C． / D) → autoSplit', () {
      const input = '下列说法正确的是\nA. 第一项\nB、第二项\nC．第三项\nD) 第四项';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.stemText, '下列说法正确的是');
    });

    test('只有 A/B 两项（分行，两强）→ autoSplit，choice_single', () {
      const input = '下列说法正确的是\nA. 第一项\nB. 第二项';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(_type(input), 'choice_single');
    });

    test('冒号式 A: 甲 → autoSplit', () {
      const input = '下列说法正确的是\nA: 甲\nB: 乙\nC: 丙\nD: 丁';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.stemText, '下列说法正确的是');
    });

    test('纯空格式 A 甲 + 完整 B/C/D 序列 → autoSplit', () {
      const input = '下列说法正确的是\nA 甲\nB 乙\nC 丙\nD 丁';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.stemText, '下列说法正确的是');
    });

    test('纯空格式但只有 A、B 且 A 为弱边界 → notSplit（不硬猜）', () {
      const input = '下列说法正确的是 A 甲 B 乙';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.notSplit);
      expect(r.stemText, input);
      expect(_type(input), isNull);
    });
  });

  group('§2.4 公式/英文/表格/div/填空冲突', () {
    test('公式变量混合：题干含 \$A\$、\$f(x)\$、化学式 AB，选项正常 → autoSplit 且切分点不在公式处', () {
      const input = r'已知 $A$ 为集合，$f(x)=x^2$，化学式 AB，求下列正确的是'
          '\nA. 甲 B. 乙 C. 丙 D. 丁';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.stemText, contains(r'$A$'));
      expect(r.cutIndex, isNotNull);
      expect(input.substring(r.cutIndex!), startsWith('A.'));
      expect(input.substring(0, r.cutIndex!), contains(r'$A$'));
    });

    test('普通英文句子含 A、B、C → notSplit', () {
      const input =
          'In this passage, A, B, C are variables. Which statement is true?';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.notSplit);
      expect(r.stemText, input);
      expect(_type(input), isNull);
    });

    test('HTML 表格选项（首列 A–D）→ autoSplit', () {
      const input = '下列说法正确的是\n'
          '<table><tr><td>A</td><td>甲</td></tr>'
          '<tr><td>B</td><td>乙</td></tr>'
          '<tr><td>C</td><td>丙</td></tr>'
          '<tr><td>D</td><td>丁</td></tr></table>';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.stemText, '下列说法正确的是');
      expect(r.cutIndex, isNotNull);
      expect(input.substring(r.cutIndex!), startsWith('<table'));
      expect(_type(input), 'choice_single');
    });

    test('div 选项块 → autoSplit', () {
      const input = '下列说法正确的是\n'
          '<div>A. 甲</div>\n<div>B. 乙</div>\n<div>C. 丙</div>\n<div>D. 丁</div>';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.stemText, '下列说法正确的是');
      expect(r.cutIndex, isNotNull);
      expect(input.substring(r.cutIndex!), startsWith('<div'));
    });

    test('单个 div 答案叙述：答案是 A，B，C 都有可能 → notSplit', () {
      const input = '<div>答案是 A，B，C 都有可能。</div>';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.notSplit);
      expect(r.stemText, input);
    });

    test('括号填空题（___）→ fill_blank', () {
      expect(_type('____ 是中国的首都，请在横线上填空。'), 'fill_blank');
    });

    test('题干同时有空括号 ( ) 与真正选项 → choice_single', () {
      const input = '下列说法正确的是（ ）\nA. 甲\nB. 乙\nC. 丙\nD. 丁';
      expect(_type(input), 'choice_single');
      expect(splitStem(input).status, StemSplitStatus.autoSplit);
    });

    test('题干只有空括号 ( ) 无选项 → 不自动定型（null）', () {
      expect(_type('中国的首都是（ ），请写出。'), isNull);
      expect(splitStem('中国的首都是（ ），请写出。').status, StemSplitStatus.notSplit);
    });
  });

  group('§2.4 两道题与顺序异常', () {
    test('两道题连续出现：第一题只有 A，第二题只有 B/C → 不得拼成一题，不切分', () {
      const input = '1. 第一题题干\n'
          'A. 选项一\n'
          '2. 第二题题干\n'
          'B. 选项二\n'
          'C. 选项三';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.notSplit);
      expect(r.stemText, input);
    });

    test('两道题连续出现：两题各有完整强选项 → 存在歧义', () {
      const input = '1. 第一题题干\n'
          'A. 选项一\n'
          'B. 选项二\n'
          '2. 第二题题干\n'
          'A. 选项三\n'
          'B. 选项四';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.ambiguous);
      expect(r.cutIndex, isNull);
      expect(r.stemText, input);
    });

    test('选项顺序缺失（A、C、D 无 B）→ notSplit', () {
      const input = '下列说法正确的是\nA. 第一项\nC. 第三项\nD. 第四项';
      expect(splitStem(input).status, StemSplitStatus.notSplit);
    });

    test('选项重复（A、B、B、C）→ notSplit', () {
      const input = '下列说法正确的是\nA. 第一项\nB. 第二项\nB. 第二项又出现\nC. 第三项';
      expect(splitStem(input).status, StemSplitStatus.notSplit);
    });

    test('选项倒序（B、A）→ notSplit', () {
      const input = '下列说法正确的是\nB. 第二项\nA. 第一项';
      expect(splitStem(input).status, StemSplitStatus.notSplit);
    });
  });

  group('R2-6 两项组合与续行', () {
    test('两项强/强 → autoSplit', () {
      const input = '下列说法正确的是\nA. 第一项\nB. 第二项';
      expect(splitStem(input).status, StemSplitStatus.autoSplit);
    });

    test('两项强/弱（A 行首强 + B 同行单空格弱）→ notSplit', () {
      const input = '下列说法正确的是\nA. 第一项 B. 第二项';
      expect(splitStem(input).status, StemSplitStatus.notSplit);
    });

    test('两项弱/弱（A、B 均为行内单空格）→ notSplit', () {
      const input = '下列说法正确的是 A. 第一项 B. 第二项';
      expect(splitStem(input).status, StemSplitStatus.notSplit);
    });

    test('选项续行含普通英文单词 → autoSplit', () {
      const input = '下列说法正确的是\n'
          'A. 第一项内容\n'
          '续行有 English 单词\n'
          'B. 第二项\n'
          'C. 第三项\n'
          'D. 第四项';
      expect(splitStem(input).status, StemSplitStatus.autoSplit);
    });

    test('选项续行含数字编号（行中数字，非行首题号）→ autoSplit', () {
      const input = '下列说法正确的是\n'
          'A. 第一项内容\n'
          '续行：共 2 步，第 3 步见图\n'
          'B. 第二项\n'
          'C. 第三项\n'
          'D. 第四项';
      expect(splitStem(input).status, StemSplitStatus.autoSplit);
    });
  });

  group('R2-6 题干编号列表与公式/代码', () {
    test('题干含编号列表 (1)(2)，无选项 → notSplit', () {
      const input = '已知函数 f(x) = x²。\n（1）求函数的定义域。\n（2）求函数的值域。';
      expect(splitStem(input).status, StemSplitStatus.notSplit);
      expect(_type(input), isNull);
    });

    test('题干含编号列表 (1)(2)，其后有选项 → autoSplit', () {
      const input = '已知函数 f(x) = x²。\n（1）求函数的定义域。\n（2）求函数的值域。\n'
          '下列说法正确的是\nA. 甲\nB. 乙\nC. 丙\nD. 丁';
      expect(splitStem(input).status, StemSplitStatus.autoSplit);
    });

    test('公式内含 A.、B) 形似选项的文本 → notSplit', () {
      const input = r'已知公式 $A. B)$ 的值，求该公式的含义。';
      expect(splitStem(input).status, StemSplitStatus.notSplit);
    });

    test('公式内含形似选项文本，但其后有真正选项 → autoSplit，切分点在真正 A 处', () {
      const input = r'已知公式 $A. B)$ 的值，下列说法正确的是'
          '\nA. 甲\nB. 乙\nC. 丙\nD. 丁';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.stemText, contains(r'$A. B)$'));
      expect(input.substring(r.cutIndex!), startsWith('A. 甲'));
    });

    test('代码块内含 A/B/C/D → notSplit', () {
      const input = '请看代码：\n```\nA. 甲\nB. 乙\nC. 丙\nD. 丁\n```';
      expect(splitStem(input).status, StemSplitStatus.notSplit);
    });

    test('行内代码内含 A/B → notSplit', () {
      const input = '代码 `A. 甲 B. 乙` 不是选项，请阅读题干。';
      expect(splitStem(input).status, StemSplitStatus.notSplit);
    });
  });

  group('R2-6 表格与五项/新题号/普通叙述', () {
    test('HTML 表格含空行、合并单元格、额外表头行 → autoSplit', () {
      const input = '下列说法正确的是\n'
          '<table>\n'
          '<tr><th>选项</th><th>内容</th></tr>\n'
          '<tr><td>A</td><td>甲</td></tr>\n'
          '<tr><td></td><td></td></tr>\n'
          '<tr><td>B</td><td>乙</td></tr>\n'
          '<tr><td>C</td><td colspan="2">丙</td></tr>\n'
          '<tr><td>D</td><td>丁</td></tr>\n'
          '</table>';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.stemText, '下列说法正确的是');
    });

    test('五项 A–E → autoSplit', () {
      const input = '下列说法正确的是\nA. 甲\nB. 乙\nC. 丙\nD. 丁\nE. 戊';
      expect(splitStem(input).status, StemSplitStatus.autoSplit);
    });

    test('两道题之间无空行但出现新题号：第一题只有 A，第二题只有 B/C → 不拼合，notSplit', () {
      const input = '1. 第一题题干\nA. 选项一\n2. 第二题题干\nB. 选项二\nC. 选项三';
      expect(splitStem(input).status, StemSplitStatus.notSplit);
    });

    test('题干含“答案是 A，B，C 都有可能”一类普通叙述 → notSplit', () {
      const input = '某题的答案是 A，B，C 都有可能，请判断该说法是否正确。';
      expect(splitStem(input).status, StemSplitStatus.notSplit);
      expect(_type(input), isNull);
    });
  });

  group('S3-1 统一词法优先级', () {
    test('代码块内含 \$A\$ 与 <table>：两路径一致处理，不切分', () {
      const input = '请看代码：\n```\n\$A\$ 是变量\n<table><tr><td>A</td><td>甲</td></tr></table>\n```';
      expect(splitStem(input).status, StemSplitStatus.notSplit);
    });

    test('公式紧闭后立即出现的标记可参与判定', () {
      const input = r'已知 $x$ 的值，下列说法正确的是'
          '\nA. 甲\nB. 乙';
      expect(splitStem(input).status, StemSplitStatus.autoSplit);
    });

    test('未闭合的 \$ 按字面处理，其后标记仍可参与判定', () {
      const input = '价格 \$5 一份，下列说法正确的是\nA. 甲\nB. 乙';
      expect(splitStem(input).status, StemSplitStatus.autoSplit);
    });

    test(r'\$ 是字面美元符，不开启公式区间', () {
      const input = r'价格 \$5，下列说法正确的是'
          '\nA. 甲\nB. 乙';
      expect(splitStem(input).status, StemSplitStatus.autoSplit);
    });
  });

  group('S3-2 行首 (n) 小问标记判别', () {
    test('小问边界防拼合：（1）后只有 A，（2）后只有 B/C → notSplit', () {
      const input = '（1）第一小问\nA. 选项一\n（2）第二小问\nB. 选项二\nC. 选项三';
      expect(splitStem(input).status, StemSplitStatus.notSplit);
    });

    test('(n) 在选项内容区间内 → 不分裂，选项序列完整', () {
      const input = '下列说法正确的是\n'
          'A. 第一项内容 (1) 续行\n'
          'B. 第二项\n'
          'C. 第三项\n'
          'D. 第四项';
      expect(splitStem(input).status, StemSplitStatus.autoSplit);
    });

    test('先出现 (2) 无 (1) 在前 → 不是小问边界，选项不受影响', () {
      const input = '（2）第二点说明\n下列说法正确的是\nA. 甲\nB. 乙';
      expect(splitStem(input).status, StemSplitStatus.autoSplit);
    });

    test('(1) 独占一行、同行无内容 → 不是小问边界，选项照常组装', () {
      const input = '（1）\nA. 甲\n（2）第二小问\nB. 乙\nC. 丙';
      expect(splitStem(input).status, StemSplitStatus.autoSplit);
    });
  });

  group('S3-2 带圈数字规范化（T2-2）', () {
    test('带圈数字小问 ①②：① 后只有 A，② 后只有 B/C → notSplit', () {
      const input = '① 第一小问\nA. 选项一\n② 第二小问\nB. 选项二\nC. 选项三';
      expect(splitStem(input).status, StemSplitStatus.notSplit);
    });
  });

  group('S3-3 嵌套表格', () {
    test('嵌套表格内的字母标记不参与选项判定：仅嵌套表有 A/B → notSplit', () {
      const input = '下列说法正确的是\n'
          '<table><tr><td>外层文字</td><td>'
          '<table><tr><td>A</td><td>甲</td></tr>'
          '<tr><td>B</td><td>乙</td></tr></table>'
          '</td></tr></table>';
      expect(splitStem(input).status, StemSplitStatus.notSplit);
    });

    test('外层表格选项正常，单元格内嵌套表不干扰 → autoSplit', () {
      const input = '下列说法正确的是\n'
          '<table><tr><td>A</td><td>甲<table><tr><td>C</td><td>嵌套</td></tr></table></td></tr>'
          '<tr><td>B</td><td>乙</td></tr></table>';
      expect(splitStem(input).status, StemSplitStatus.autoSplit);
    });
  });

  group('R2-4 表格 A–E 统一规则', () {
    test('表格仅 A/B 两行：首列 A、B 且第二列内容非空 → autoSplit', () {
      const input = '下列说法正确的是\n'
          '<table><tr><td>A</td><td>甲</td></tr>'
          '<tr><td>B</td><td>乙</td></tr></table>';
      expect(splitStem(input).status, StemSplitStatus.autoSplit);
    });

    test('表格缺号 A/B/C/E（缺 D）→ notSplit', () {
      const input = '下列说法正确的是\n'
          '<table><tr><td>A</td><td>甲</td></tr>'
          '<tr><td>B</td><td>乙</td></tr>'
          '<tr><td>C</td><td>丙</td></tr>'
          '<tr><td>E</td><td>戊</td></tr></table>';
      expect(splitStem(input).status, StemSplitStatus.notSplit);
    });

    test('E 只允许紧跟 D 之后：A/B/C/E → notSplit', () {
      const input = '下列说法正确的是\nA. 甲\nB. 乙\nC. 丙\nE. 戊';
      expect(splitStem(input).status, StemSplitStatus.notSplit);
    });

    test('非首列出现的字母标记一律忽略 → notSplit', () {
      const input = '下列说法正确的是\n'
          '<table><tr><td>甲</td><td>A. 乙</td></tr>'
          '<tr><td>丙</td><td>B. 丁</td></tr></table>';
      expect(splitStem(input).status, StemSplitStatus.notSplit);
    });

    test('div 连续块被非选项 div 中断 → notSplit', () {
      const input = '下列说法正确的是\n'
          '<div>A. 甲</div>\n<div>说明文字</div>\n<div>B. 乙</div>';
      expect(splitStem(input).status, StemSplitStatus.notSplit);
    });
  });

  group('U4-1 占位符处理顺序与位置映射', () {
    test('多行代码块后的 (1) 小问与选项：切分点映射回原始文本', () {
      const input = '请看代码：\n```\nA. 甲\nB. 乙\n```\n'
          '（1）第一小问\nA. 选项一\nB. 选项二';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.cutIndex, isNotNull);
      expect(input.substring(r.cutIndex!), startsWith('A. 选项一'));
      expect(r.stemText, contains('```'));
      expect(r.stemText, contains('（1）第一小问'));
    });

    test('HTML 实体不破坏切分点映射', () {
      const input = '已知 A &lt; B，下列说法正确的是\nA. 甲\nB. 乙';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.cutIndex, isNotNull);
      expect(input.substring(r.cutIndex!), startsWith('A. 甲'));
    });

    test('行内反引号与围栏块重叠不抛 RangeError（协调员补测：U4-1 代码保护）', () {
      // 行内段 `a 从 0 起、止于围栏块的开围栏内，与 fenced span [3,10) 重叠；
      // 旧守卫只跳过起点落在已有 span 内的匹配，会留下重叠 span 并在重建时抛错。
      const input = '`a ```b```\n下列说法正确的是\nA. 甲\nB. 乙';
      final r = splitStem(input);
      expect(r.reason, isNotEmpty);
    });
  });

  group('分类器：选择与填空冲突处理（§2.2 步骤 4）', () {
    test('只有裸空括号 ( ) + 简述动词 → 不自动定型（null，不硬猜）', () {
      expect(_type('请简述（ ）的含义。'), isNull);
    });

    test('空括号 + 强填空 ___ → fill_blank', () {
      expect(_type('____（ ）是中国的首都。'), 'fill_blank');
    });

    test('填空关键词“填空”无下划线 → fill_blank', () {
      expect(_type('填空题：中国的首都是哪里？'), 'fill_blank');
    });

    test('选择题 + 强填空 ___ 同时出现 → 选择题优先', () {
      const input = '下列说法正确的是 ____\nA. 甲\nB. 乙\nC. 丙\nD. 丁';
      expect(_type(input), 'choice_single');
    });

    test('代码块内 ①②③④ 不是选项 → 不判选择题', () {
      const input = '```\n①苹果\n②香蕉\n③橙子\n④葡萄\n```';
      expect(_type(input), isNull);
    });
  });

  group('结果结构', () {
    test('自动切分时 cutIndex 指向 A 标记或选项容器起点，stemText 与原文前缀一致', () {
      const input = '5. 下列正确的是\n\nA. 第一项\nB. 第二项';
      final r = splitStem(input);
      expect(r.cutIndex, input.indexOf('A. 第一项'));
      expect(r.stemText, input.substring(0, r.cutIndex).trim());
    });

    test('reason 都不为空，且切分器永不产出“人工调整”', () {
      const inputs = [
        '下列说法正确的是 A. 甲 B. 乙 C. 丙 D. 丁',
        '下列说法正确的是\nA. 第一项\nB. 第二项',
        '中国的首都是（ ），请写出。',
        '请看代码：\n```\nA. 甲\nB. 乙\n```',
      ];
      for (final input in inputs) {
        final r = splitStem(input);
        expect(r.reason, isNotEmpty);
        expect(r.status, isNot(StemSplitStatus.manuallyAdjusted));
      }
    });
  });
}
