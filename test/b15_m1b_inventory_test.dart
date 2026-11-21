// 十五批 M1-B：盘点 M1-0 测试（M1-DESIGN.md §5）。
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/modules/ocr/ocr_figures.dart';
import 'package:quiz_master2/services/pdf_export/export_inventory.dart';
import 'package:quiz_master2/services/pdf_export/export_question_record.dart';
import 'package:quiz_master2/services/pdf_export/export_route.dart';
import 'package:quiz_master2/services/pdf_export/export_snapshot.dart';

import 'b15_m1b_fake_source.dart';

void main() {
  late FakeExportQuestionSource source;

  setUp(() {
    source = FakeExportQuestionSource();
  });

  Future<ExportInventory> inventoryC(
    List<ExportQuestionRecord> selected, {
    int circledCount = 0,
    List<ExcludedQuestion> excluded = const [],
  }) {
    return runInventory(
      decision: const ExportRouteDecision(
        route: ExportRoute.c,
        reason: '已配置 OCR key',
      ),
      circledCount: circledCount == 0 ? selected.length : circledCount,
      selected: selected,
      excluded: excluded,
      source: source,
    );
  }

  Future<ExportInventory> inventoryA(
    List<ExportQuestionRecord> selected, {
    int circledCount = 0,
    List<ExcludedQuestion> excluded = const [],
  }) {
    return runInventory(
      decision: const ExportRouteDecision(
        route: ExportRoute.a,
        reason: '未配置 OCR key',
      ),
      circledCount: circledCount == 0 ? selected.length : circledCount,
      selected: selected,
      excluded: excluded,
      source: source,
    );
  }

  void addChoice(String id) {
    source.records[id] = choiceRecord(id: id);
    source.slices[id] = makePng(200, 100);
  }

  group('C 路线盘点', () {
    test('全部可印：四种题数区分正确', () async {
      addChoice('q1');
      addChoice('q2');
      final inv = await inventoryC(
        [source.records['q1']!, source.records['q2']!],
        circledCount: 10,
      );
      expect(inv.route, ExportRoute.c);
      expect(inv.circledCount, 10);
      expect(inv.selectedCount, 2);
      expect(inv.printableCount, 2);
      expect(inv.skippedCount, 0);
      expect(inv.hasPrintable, isTrue);
      expect(inv.needsSecondConfirmation, isFalse);
      expect(inv.conservationError(), isNull);
    });

    test('跳过清单：无 OCR 结果 / 题干缺失 / 选项无法派生各记原因', () async {
      source.records['q1'] = choiceRecord(id: 'q1', ocrRaw: null);
      source.records['q2'] = choiceRecord(id: 'q2', ocrStem: '  ');
      source.records['q3'] = choiceRecord(
        id: 'q3',
        ocrStem: '求值',
        ocrRaw: mdRaw(choiceMd('求值')),
        optionContentsJson: null,
        options: const {},
      );
      addChoice('q4');
      final inv = await inventoryC([
        source.records['q1']!,
        source.records['q2']!,
        source.records['q3']!,
        source.records['q4']!,
      ]);
      expect(inv.printableCount, 1);
      expect(inv.skippedCount, 3);
      expect(
        inv.skipped.map((s) => s.reason),
        ['无 OCR 结果', '题干缺失', '选项无法派生'],
      );
      expect(inv.skipped.map((s) => s.questionId), ['q1', 'q2', 'q3']);
    });

    test('可疑清单：选项切分不确定但已印的题进清单', () async {
      source.records['q1'] = choiceRecord(
        id: 'q1',
        options: {'A': '甲', 'C': '丙', 'D': '丁'},
      );
      final inv = await inventoryC([source.records['q1']!]);
      expect(inv.printableCount, 1);
      expect(inv.suspicious.length, 1);
      expect(inv.suspicious.single.flags, contains('optionSplitUncertain'));
    });

    test('可印题数为 0 → 不生成 PDF、不建快照（hasPrintable 为 false）', () async {
      source.records['q1'] = choiceRecord(id: 'q1', ocrRaw: null);
      final inv = await inventoryC([source.records['q1']!]);
      expect(inv.printableCount, 0);
      expect(inv.hasPrintable, isFalse);
      expect(inv.skippedCount, 1);
    });

    test('guard 预估进盘点输出，标注“估算值”', () async {
      addChoice('q1');
      final inv = await inventoryC([source.records['q1']!]);
      expect(inv.guard.isEstimate, isTrue);
      expect(inv.guard.totalRasterMpx, greaterThanOrEqualTo(0));
      expect(inv.guard.estimatedSaveMb, greaterThanOrEqualTo(0));
    });

    test('C 路线 guard 估算含公式与图块（非零）', () async {
      final sliceBytes = makePng(200, 100);
      source.records['q1'] = choiceRecord(
        id: 'q1',
        slicePath: 'slices/q1.png',
        sliceWidth: 200,
        sliceHeight: 100,
        ocrStem: r'设 $a$ 为常数，求 $$b$$ 的值',
        ocrRaw: mdRaw(choiceMd(r'设 $a$ 为常数，求 $$b$$ 的值')),
        ocrFigures: singleFigureJson(
          questionId: 'q1',
          slicePath: 'slices/q1.png',
          sliceBytes: sliceBytes,
          srcRect: const SrcRect(x: 10, y: 10, width: 50, height: 40),
        ),
      );
      source.slices['q1'] = sliceBytes;
      final inv = await inventoryC([source.records['q1']!]);
      expect(inv.printableCount, 1);
      // 1 行内公式 + 1 独立公式 + 1 图块（250×200 px 区域）> 0。
      expect(inv.guard.totalRasterMpx, greaterThan(0.1));
    });
  });

  group('A 路线盘点', () {
    test('切片可用 → 可印；DPI 分布进清单', () async {
      // 200 px 宽在内容区宽下约 28 DPI → 低于 150，明显偏低。
      source.records['q1'] = choiceRecord(id: 'q1');
      source.slices['q1'] = makePng(200, 100);
      // 3000 px 宽约 424 DPI → 正常。
      source.records['q2'] = choiceRecord(id: 'q2');
      source.slices['q2'] = makePng(3000, 2000);
      final inv = await inventoryA([
        source.records['q1']!,
        source.records['q2']!,
      ]);
      expect(inv.printableCount, 2);
      expect(inv.lowDpi.length, 1);
      expect(inv.lowDpi.single.questionId, 'q1');
      expect(inv.lowDpi.single.severe, isTrue);
    });

    test('DPI 150–200 为警告档（不明显）', () async {
      source.records['q1'] = choiceRecord(id: 'q1');
      // 1200 px 宽 ≈ 169 DPI。
      source.slices['q1'] = makePng(1200, 800);
      final inv = await inventoryA([source.records['q1']!]);
      expect(inv.lowDpi.length, 1);
      expect(inv.lowDpi.single.severe, isFalse);
      expect(inv.lowDpi.single.dpi, closeTo(169, 2));
    });

    test('切片缺失 → 跳过，原因“切片不可用”', () async {
      source.records['q1'] = choiceRecord(id: 'q1');
      // 不放切片字节。
      final inv = await inventoryA([source.records['q1']!]);
      expect(inv.printableCount, 0);
      expect(inv.skipped.single.reason, '切片不可用');
      expect(inv.hasPrintable, isFalse);
    });

    test('切片损坏（非 PNG）→ 跳过', () async {
      source.records['q1'] = choiceRecord(id: 'q1');
      source.slices['q1'] = makePngHeadOnly(100, 100).sublist(0, 10);
      final inv = await inventoryA([source.records['q1']!]);
      expect(inv.printableCount, 0);
      expect(inv.skipped.single.reason, '切片不可用');
    });

    test('A 路线 guard 估算：3000×2000 切片约 6 Mpx（未超上限不缩放）',
        () async {
      source.records['q1'] = choiceRecord(id: 'q1');
      source.slices['q1'] = makePng(3000, 2000);
      final inv = await inventoryA([source.records['q1']!]);
      // 3000 > 2126 → 下采样：2126 × (2000×2126/3000) ≈ 3.01 Mpx。
      expect(inv.guard.totalRasterMpx, closeTo(3.01, 0.05));
    });
  });

  group('二次确认标记（跳过数 > 20 或 > 50%）', () {
    test('跳过 21 道 → 须二次确认', () async {
      final selected = <ExportQuestionRecord>[];
      for (var i = 0; i < 30; i++) {
        final id = 'q$i';
        source.records[id] = choiceRecord(id: id, ocrRaw: null);
        selected.add(source.records[id]!);
      }
      final inv = await inventoryC(selected);
      expect(inv.skippedCount, 30);
      expect(inv.needsSecondConfirmation, isTrue);
    });

    test('跳过 20 道且比例 ≤ 50% → 不须二次确认', () async {
      final selected = <ExportQuestionRecord>[];
      for (var i = 0; i < 40; i++) {
        final id = 'q$i';
        if (i < 20) {
          source.records[id] = choiceRecord(id: id, ocrRaw: null);
        } else {
          addChoice(id);
        }
        selected.add(source.records[id]!);
      }
      final inv = await inventoryC(selected);
      expect(inv.skippedCount, 20);
      expect(inv.needsSecondConfirmation, isFalse);
    });

    test('跳过比例 > 50%（11/20）→ 须二次确认', () async {
      final selected = <ExportQuestionRecord>[];
      for (var i = 0; i < 20; i++) {
        final id = 'q$i';
        if (i < 11) {
          source.records[id] = choiceRecord(id: id, ocrRaw: null);
        } else {
          addChoice(id);
        }
        selected.add(source.records[id]!);
      }
      final inv = await inventoryC(selected);
      expect(inv.skippedCount, 11);
      expect(inv.needsSecondConfirmation, isTrue);
    });
  });

  group('排除题与守恒', () {
    test('排除题计入已选，不计入可印/跳过', () async {
      addChoice('q1');
      addChoice('q2');
      final inv = await inventoryC(
        [source.records['q1']!, source.records['q2']!],
        excluded: const [ExcludedQuestion(id: 'q2', reason: '用户主动排除')],
      );
      expect(inv.selectedCount, 2);
      expect(inv.printableCount, 1);
      expect(inv.skippedCount, 0);
      expect(inv.excluded.length, 1);
      expect(inv.conservationError(), isNull);
    });
  });
}
