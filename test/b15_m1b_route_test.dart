// 十五批 M1-B：路由判定 + 50 道上限选择接口测试（M1-DESIGN.md §2/§5）。
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/services/pdf_export/export_route.dart';

void main() {
  group('路由判定（C-8）', () {
    test('有 key → C 路线', () async {
      final decision =
          await resolveExportRoute(hasApiKey: () async => true);
      expect(decision.route, ExportRoute.c);
      expect(decision.reason, '已配置 OCR key');
      expect(decision.notice, contains('OCR 重排路线'));
      expect(decision.notice, contains('不会自动补跑 OCR'));
    });

    test('无 key → 整单 A 路线', () async {
      final decision =
          await resolveExportRoute(hasApiKey: () async => false);
      expect(decision.route, ExportRoute.a);
      expect(decision.reason, '未配置 OCR key');
      expect(decision.notice, contains('图片增强路线'));
      expect(decision.notice, contains('去设置页配置 OCR key'));
    });

    test('读 key 状态失败 → 整单失败，不静默按任一路线继续', () async {
      expect(
        () => resolveExportRoute(
          hasApiKey: () => throw StateError('secure storage boom'),
        ),
        throwsA(
          isA<RouteResolutionException>().having(
            (e) => e.message,
            'message',
            contains('读取 OCR key 状态失败'),
          ),
        ),
      );
    });

    test('读 key 状态失败的报错不含 key 本身', () async {
      try {
        await resolveExportRoute(
          hasApiKey: () => throw Exception('boom'),
        );
        fail('应抛错');
      } on RouteResolutionException catch (e) {
        expect(e.message, isNot(contains('bigmodel')));
        expect(e.toString(), isNot(contains('sk-')));
      }
    });
  });

  group('50 道上限选择接口（§2 第 1 点）', () {
    test('上限值 50', () {
      expect(kExportMaxQuestions, 50);
    });

    test('选中 ≤ 50 允许', () {
      expect(
        checkSelectionCap(List.generate(50, (i) => 'q$i')).allowed,
        isTrue,
      );
      expect(
        checkSelectionCap(List.generate(49, (i) => 'q$i')).allowed,
        isTrue,
      );
      expect(checkSelectionCap(const []).allowed, isTrue);
    });

    test('选中 51 拒绝 + 原因“单次最多导出 50 道题”', () {
      final result =
          checkSelectionCap(List.generate(51, (i) => 'q$i'));
      expect(result.allowed, isFalse);
      expect(result.reason, '单次最多导出 50 道题');
    });

    test('全选 = 范围前 50 道 + 明示文案（Q2 定稿）', () {
      final range = List.generate(120, (i) => 'q$i');
      final (selectedIds: selected, notice: notice) =
          selectFirst50(range);
      expect(selected, List.generate(50, (i) => 'q$i'));
      expect(
        notice,
        '范围共 120 道，已按当前排序选中前 50 道，'
        '其余题目未选中。你可以调整本次选择。',
      );
    });

    test('范围不足 50 道时全选即全部', () {
      final range = List.generate(3, (i) => 'q$i');
      final (selectedIds: selected, notice: notice) =
          selectFirst50(range);
      expect(selected, ['q0', 'q1', 'q2']);
      expect(notice, contains('范围共 3 道'));
    });

    test('全选不把其余题目放进隐藏待导出队列', () {
      final range = List.generate(60, (i) => 'q$i');
      final (selectedIds: selected, notice: _) = selectFirst50(range);
      expect(selected.length, 50);
      expect(selected, isNot(contains('q50')));
    });
  });
}
