// 十六批 D-189：assembleCMarkdown 无条件追加选项块导致选项印两遍的
// 回归测试（PDF-DEFECT-ROOT-CAUSE.md §2）。
//
// 缺陷：题干已含内嵌选项 + option_contents 非空并存的遗留行，
// assembleCMarkdown 不检查题干就把选项块追加到题干后 → 同一选项
// 出现两遍（第 2、3、5、6、10 题）。
// 修法：追加前对冻结后的题干跑 splitStem（_stemOptionLabels，
// assessCPrintability 与 assembleCMarkdown 同一口径）：全覆盖 →
// 视同 inlineInStem + 标 optionSplitUncertain，不追加；部分覆盖 →
// 逐标签去重，只追加题干里没有的标签。检测只读冻结后的 ocrStem，
// 不回写、不改库（D-177）。
//
// 另含缺陷 3 的锁定测试：option_contents 四项全为公式字符串时
// nonEmpty 计为 4、判定为 available（防将来把“公式不算内容”误修进去）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/modules/ocr/question_content.dart';
import 'package:quiz_master2/services/pdf_export/ocr_content_snapshot.dart';
import 'package:quiz_master2/services/stem_splitter.dart';

import 'b15_m1b_fake_source.dart';

/// [needle] 在 [haystack] 里不重叠出现的次数。
int _countOccurrences(String haystack, String needle) {
  var count = 0;
  var from = 0;
  while (true) {
    final i = haystack.indexOf(needle, from);
    if (i < 0) return count;
    count++;
    from = i + needle.length;
  }
}

/// 断言每个选项在最终 Markdown 里恰好出现一次。
void _expectEachOptionOnce(String markdown, Map<String, String> options) {
  for (final entry in options.entries) {
    final rendered = '${entry.key}. ${entry.value}';
    expect(
      _countOccurrences(markdown, rendered),
      1,
      reason: '选项 $rendered 在最终 Markdown 里应恰好出现一次',
    );
  }
}

void main() {
  group('D-189 缺陷 2：题干含选项 + option_contents 非空 → 不重复', () {
    test('题干含全部选项：每个选项恰好出现一次，不追加选项块', () {
      const stem = '求值\nA. 甲\nB. 乙\nC. 丙\nD. 丁';
      final record = choiceRecord(id: 'q1', ocrStem: stem);
      final printability = assessCPrintability(record);
      expect(printability.printable, isTrue);
      expect(
        printability.optionsState,
        OptionsState.inlineInStem,
        reason: '题干已含全部选项，视同 inlineInStem',
      );
      expect(
        printability.suspiciousFlags,
        contains('optionSplitUncertain'),
      );
      final markdown = assembleCMarkdown(record, printability);
      expect(markdown, stem);
      _expectEachOptionOnce(
        markdown,
        {'A': '甲', 'B': '乙', 'C': '丙', 'D': '丁'},
      );
    });

    test('题干只含部分标签（A/B）：A/B 只在题干出现，C/D 追加一次', () {
      const stem = '求值\nA. 甲\nB. 乙';
      final record = choiceRecord(id: 'q1', ocrStem: stem);
      final printability = assessCPrintability(record);
      expect(printability.printable, isTrue);
      final markdown = assembleCMarkdown(record, printability);
      _expectEachOptionOnce(
        markdown,
        {'A': '甲', 'B': '乙', 'C': '丙', 'D': '丁'},
      );
      // C/D 不在题干里，应由追加块补齐；A/B 不重复追加。
      expect(markdown, contains('C. 丙'));
      expect(markdown, contains('D. 丁'));
    });

    test('题干无选项：选项块照常追加一次（既有行为不变）', () {
      final record = choiceRecord(id: 'q1', ocrStem: '求下列各题的值');
      final printability = assessCPrintability(record);
      expect(printability.optionsState, OptionsState.available);
      final markdown = assembleCMarkdown(record, printability);
      _expectEachOptionOnce(
        markdown,
        {'A': '甲', 'B': '乙', 'C': '丙', 'D': '丁'},
      );
    });

    test('端到端：快照块序列里每个选项恰好出现一次', () async {
      const stem = '求值\nA. 甲\nB. 乙\nC. 丙\nD. 丁';
      final record = choiceRecord(id: 'q1', ocrStem: stem);
      final tempRoot = await Directory.systemTemp.createTemp('b16-d189-');
      final figureDir = Directory('${tempRoot.path}/figures');
      await figureDir.create();
      try {
        final snap = await buildOcrContentSnapshot(
          record: record,
          sliceBytes: null,
          sliceHash: null,
          figureTempDir: figureDir,
        );
        expect(snap.printable, isTrue);
        final text = snap.blocks
            .whereType<TextBlock>()
            .map((b) => b.text)
            .join('\n');
        _expectEachOptionOnce(
          text,
          {'A': '甲', 'B': '乙', 'C': '丙', 'D': '丁'},
        );
      } finally {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      }
    });
  });

  group('D-205 锁定：题干无法自动切分（ambiguous / notSplit）→ 不去重、全量追加', () {
    test('ambiguous（一框两题，两个可信 A）：选项块全量追加一次', () {
      // b13 同款输入：两个可信 A 候选 → ambiguous，整段保留为题干。
      const stem = '1. 第一题题干\n\nA. 选项一\nB. 选项二\n\n'
          '2. 第二题题干\n\nA. 选项三\nB. 选项四';
      expect(
        splitStem(stem).status,
        StemSplitStatus.ambiguous,
        reason: '前置条件：该题干无法自动切分',
      );
      final record = choiceRecord(id: 'q1', ocrStem: stem);
      final printability = assessCPrintability(record);
      expect(printability.printable, isTrue);
      // 情形 (d) 下标签正常：判 available，不标 optionSplitUncertain。
      expect(printability.optionsState, OptionsState.available);
      expect(printability.suspiciousFlags, isEmpty);
      final markdown = assembleCMarkdown(record, printability);
      // 选项块完整出现一次（全量追加，不去重）。
      expect(
        _countOccurrences(markdown, 'A. 甲\nB. 乙\nC. 丙\nD. 丁'),
        1,
        reason: '选项块应完整追加一次',
      );
      expect(markdown, startsWith(stem));
    });

    test('notSplit（题干含 A、C，B 缺失）：选项块全量追加，A/C 各出现两次', () {
      const stem = '求值\nA. 甲\nC. 丙';
      expect(
        splitStem(stem).status,
        StemSplitStatus.notSplit,
        reason: '前置条件：序列缺 B，无法自动切分',
      );
      final record = choiceRecord(id: 'q1', ocrStem: stem);
      final printability = assessCPrintability(record);
      expect(printability.printable, isTrue);
      expect(printability.optionsState, OptionsState.available);
      expect(printability.suspiciousFlags, isEmpty);
      final markdown = assembleCMarkdown(record, printability);
      // 已接受的降级：题干里的 A/C 与追加块重复出现（宁可重复也不丢选项）。
      expect(_countOccurrences(markdown, 'A. 甲'), 2);
      expect(_countOccurrences(markdown, 'C. 丙'), 2);
      expect(_countOccurrences(markdown, 'B. 乙'), 1);
      expect(_countOccurrences(markdown, 'D. 丁'), 1);
      expect(
        _countOccurrences(markdown, 'A. 甲\nB. 乙\nC. 丙\nD. 丁'),
        1,
        reason: '选项块应完整追加一次',
      );
      expect(markdown, startsWith(stem));
    });
  });

  group('D-189 锁定：缺陷 3 四项全公式字符串的选项仍判可印', () {
    test('option_contents 四项全为公式字符串 → nonEmpty 计为 4、available', () {
      final record = choiceRecord(
        id: 'q1',
        ocrStem: '求值',
        options: {
          'A': r'$ x+y-\pi-2=0 $',
          'B': r'$ \frac{63}{16} $',
          'C': r'$ \frac{1}{4} $',
          'D': r'$ \sin x $',
        },
      );
      final printability = assessCPrintability(record);
      expect(printability.printable, isTrue);
      expect(
        printability.optionsState,
        OptionsState.available,
        reason: '公式字符串是非空选项内容，不得按空槽处理',
      );
      expect(printability.suspiciousFlags, isEmpty);
      final markdown = assembleCMarkdown(record, printability);
      _expectEachOptionOnce(
        markdown,
        {
          'A': r'$ x+y-\pi-2=0 $',
          'B': r'$ \frac{63}{16} $',
          'C': r'$ \frac{1}{4} $',
          'D': r'$ \sin x $',
        },
      );
    });
  });
}
