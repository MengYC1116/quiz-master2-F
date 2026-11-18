// 十二批功能 8 Stage B：Dart 版 XY-cut 题序夹具测试（D-96）。
//
// 只写测试 + 夹具，绝不改 lib/ 下任何产品代码。
//
// 夹具来源（直接拷贝，未手抄数字）：
// - test/fixtures/b12_stage_a/detect/：Stage A 检测框（37 页，生产 YOLO 第 1 层）
// - test/fixtures/b12_stage_a/truth/：Stage A 真值（37 页，order 只含题内容框）
// - test/fixtures/b12_stage_a/out/：Stage A Python 脚本输出（37 页 + summary.json）
// 原始位置：~/workspace/batch12-work/stage-a/{detect,truth,out}/。
// 计数口径与 Stage A 报告 §1 一字不差：可评页 = detection_complete=true
// 且题框 >= 2，共 30 页；其余 7 页不进题序正确率分母。
// 结论口径见 ~/workspace/batch12-work/STAGE-A-REPORT.md（§5 指标、§6 局限）
// 与 docs/decision-log.md 的 D-95（Stage A 结论）、D-96（Stage B 设计）。
//
// flutter test 的 cwd 是包根目录，File('test/fixtures/...') 可读。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/question_order.dart';

/// Stage A 验证集 37 页（单 5 / 双 12 / 三 11 / 拼 5 / 边界 4；
/// collage-04/07 是答案页，已剔除，无 truth，不在内）。
const _pages = <String>[
  'collage-01',
  'collage-02',
  'collage-03',
  'collage-05',
  'collage-06',
  'double-01',
  'double-02',
  'double-03',
  'double-04',
  'double-05',
  'double-06',
  'double-07',
  'double-08',
  'double-09',
  'double-10',
  'double-11',
  'double-12',
  'edge-01',
  'edge-02',
  'edge-03',
  'edge-04',
  'single-01',
  'single-02',
  'single-03',
  'single-04',
  'single-05',
  'triple-01',
  'triple-02',
  'triple-03',
  'triple-04',
  'triple-05',
  'triple-06',
  'triple-07',
  'triple-08',
  'triple-09',
  'triple-10',
  'triple-11',
];

/// 7 页非可评页（Stage A §1.2 口径：检测不全，不进题序分母）。
const _nonEvaluablePages = <String>{
  'collage-02',
  'collage-03',
  'collage-05',
  'collage-06',
  'edge-03',
  'edge-04',
  'triple-08',
};

QuestionBox _box({
  required String id,
  double x = 0.1,
  double y = 0.1,
  double w = 0.5,
  double h = 0.3,
}) => QuestionBox(
  id: id,
  layer: 1,
  type: 'question',
  x: x,
  y: y,
  w: w,
  h: h,
);

Map<String, dynamic> _loadJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

/// 一页的全部夹具：检测框 + 真值 + Python 输出。
class _PageFixture {
  _PageFixture(this.page)
    : detect = _loadJson('test/fixtures/b12_stage_a/detect/$page.json'),
      truth = _loadJson('test/fixtures/b12_stage_a/truth/$page.json'),
      pyOut = _loadJson('test/fixtures/b12_stage_a/out/$page.json');

  final String page;
  final Map<String, dynamic> detect;
  final Map<String, dynamic> truth;
  final Map<String, dynamic> pyOut;

  List<QuestionBox> get boxes => (detect['boxes'] as List)
      .map(
        (b) => _box(
          id: b['id'] as String,
          x: (b['x'] as num).toDouble(),
          y: (b['y'] as num).toDouble(),
          w: (b['w'] as num).toDouble(),
          h: (b['h'] as num).toDouble(),
        ),
      )
      .toList();

  /// 真值顺序（只含题内容框；纯标题/指令行等误检框已排除）。
  List<String> get truthOrder =>
      (truth['order'] as List).map((e) => e as String).toList();

  String get layout => truth['layout'] as String;

  /// 可评页口径（Stage A §1.2）：detection_complete=true 且题框 >= 2。
  bool get evaluable =>
      truth['detection_complete'] == true && truthOrder.length >= 2;

  /// Python 输出的算法顺序（已过滤到题内容框）。
  List<String> get pyAlgOrder =>
      (pyOut['alg_order'] as List).map((e) => e as String).toList();

  String get pyConfidence => pyOut['confidence'] as String;
}

/// Dart 顺序过滤到真值题框 id 后，与 Python 的 alg_order 比对。
List<String> _dartFilteredOrder(_PageFixture f) {
  final result = QuestionOrder.orderBoxes(f.boxes);
  final q = f.truthOrder.toSet();
  return result.boxes.map((b) => b.id).where(q.contains).toList();
}

String _dartConfidence(_PageFixture f) =>
    QuestionOrder.orderBoxes(f.boxes).confidence.name;

/// 朴素 y-then-x 排序（测试内联实现，不调产品代码）：当前生产顺序的基线。
List<String> _naiveYxOrder(_PageFixture f) {
  final sorted = List.of(f.boxes)
    ..sort((a, b) {
      final dy = a.y.compareTo(b.y);
      return dy != 0 ? dy : a.x.compareTo(b.x);
    });
  final q = f.truthOrder.toSet();
  return sorted.map((b) => b.id).where(q.contains).toList();
}

bool _sameOrder(List<String> a, List<String> b) =>
    a.length == b.length &&
    a.asMap().entries.every((e) => e.value == b[e.key]);

void main() {
  group('Stage B 夹具：Dart XY-cut vs Stage A Python（37 页）', () {
    test('移植保真：37 页逐页 Dart 顺序与置信度 == Python 输出', () {
      final failures = <String>[];
      for (final page in _pages) {
        final f = _PageFixture(page);
        final dartOrder = _dartFilteredOrder(f);
        if (!_sameOrder(dartOrder, f.pyAlgOrder)) {
          failures.add(
            '$page 顺序不一致：Dart=$dartOrder Python=${f.pyAlgOrder}',
          );
        }
        if (_dartConfidence(f) != f.pyConfidence) {
          failures.add(
            '$page 置信度不一致：Dart=${_dartConfidence(f)} '
            'Python=${f.pyConfidence}',
          );
        }
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
    });

    test('题序正确：30 页可评页逐页 Dart 顺序 == 真值 order', () {
      final failures = <String>[];
      var evaluableCount = 0;
      for (final page in _pages) {
        final f = _PageFixture(page);
        // 口径自检：可评页集合必须与 Stage A 报告一致（30 页）。
        expect(
          f.evaluable,
          !_nonEvaluablePages.contains(page),
          reason: '$page 可评性与预期 7 页非可评集合不符',
        );
        if (!f.evaluable) continue;
        evaluableCount++;
        final dartOrder = _dartFilteredOrder(f);
        if (!_sameOrder(dartOrder, f.truthOrder)) {
          failures.add(
            '$page 排错：Dart=$dartOrder 真值=${f.truthOrder}',
          );
        }
        // 30 页可评页 Python 置信度应全是 high（Stage A §5.1，转人工 0/30）。
        expect(
          f.pyConfidence,
          'high',
          reason: '$page Python 置信度不是 high',
        );
        expect(
          _dartConfidence(f),
          'high',
          reason: '$page Dart 置信度不是 high',
        );
      }
      expect(evaluableCount, 30, reason: '可评页不是 30 页');
      expect(failures, isEmpty, reason: failures.join('\n'));
    });

    test('题序正确：分版式汇总（单 5/5、双 12/12、三 10/10、拼 1/1、边界 2/2）', () {
      final counts = <String, int>{};
      final exact = <String, int>{};
      for (final page in _pages) {
        final f = _PageFixture(page);
        if (!f.evaluable) continue;
        counts[f.layout] = (counts[f.layout] ?? 0) + 1;
        if (_sameOrder(_dartFilteredOrder(f), f.truthOrder)) {
          exact[f.layout] = (exact[f.layout] ?? 0) + 1;
        }
      }
      expect(counts, {
        'single': 5,
        'double': 12,
        'triple': 10,
        'collage': 1,
        'edge': 2,
      });
      expect(exact, {
        'single': 5,
        'double': 12,
        'triple': 10,
        'collage': 1,
        'edge': 2,
      });
    });

    test('基线锁定：朴素 y-then-x 在 30 页里只对 8 页（2009 上海卷 bug 回归锁）', () {
      final counts = <String, int>{};
      final exact = <String, int>{};
      var total = 0;
      var totalExact = 0;
      for (final page in _pages) {
        final f = _PageFixture(page);
        if (!f.evaluable) continue;
        total++;
        counts[f.layout] = (counts[f.layout] ?? 0) + 1;
        if (_sameOrder(_naiveYxOrder(f), f.truthOrder)) {
          totalExact++;
          exact[f.layout] = (exact[f.layout] ?? 0) + 1;
        }
      }
      expect(total, 30);
      // 与 Stage A §5.2 一字不差：单 5/5、双 0/12、三 2/10、拼 1/1、边界 0/2。
      expect(totalExact, 8, reason: '朴素 y-then-x 全页正确数不是 8 页');
      expect(exact['single'] ?? 0, 5);
      expect(exact['double'] ?? 0, 0);
      expect(exact['triple'] ?? 0, 2);
      expect(exact['collage'] ?? 0, 1);
      expect(exact['edge'] ?? 0, 0);
      // 多栏页（双/三/边界）基本全错：24 页里只对 2 页。
      final multiExact =
          (exact['double'] ?? 0) + (exact['triple'] ?? 0) + (exact['edge'] ?? 0);
      expect(multiExact, 2);
    });

    test('7 页非可评页：orderBoxes 不抛错、框集合不变、置信度确定', () {
      for (final page in _nonEvaluablePages) {
        final f = _PageFixture(page);
        final first = QuestionOrder.orderBoxes(f.boxes);
        final second = QuestionOrder.orderBoxes(f.boxes);
        // 同一批框两次调用结果一致（纯函数，置信度确定）。
        expect(
          second.boxes.map((b) => b.id).toList(),
          first.boxes.map((b) => b.id).toList(),
          reason: '$page 两次调用顺序不一致',
        );
        expect(
          second.confidence,
          first.confidence,
          reason: '$page 两次调用置信度不一致',
        );
        // 不丢框、不增框。
        expect(
          first.boxes.map((b) => b.id).toSet(),
          f.boxes.map((b) => b.id).toSet(),
          reason: '$page 输出框集合与输入不一致',
        );
      }
      // collage-03 是 0 框页：空进空出、high。
      final empty = _PageFixture('collage-03');
      expect(empty.boxes, isEmpty);
      final r = QuestionOrder.orderBoxes(empty.boxes);
      expect(r.boxes, isEmpty);
      expect(r.confidence, QuestionOrderConfidence.high);
    });
  });

  group('低置信度合成用例（手工造框，不依赖夹具）', () {
    test('栏数不一致 → low：两框并排、x 间隙 0.0035', () {
      // 投影法：间隙 0.0035 < minGapW 0.004，只认 1 栏；
      // 区间链接：间隙 0.0035 > chainTol 0.003，认 2 栏 → 不一致。
      final boxes = [
        _box(id: 'a', x: 0.1, y: 0.1, w: 0.4, h: 0.2),
        _box(id: 'b', x: 0.5035, y: 0.12, w: 0.4, h: 0.2),
      ];
      final r = QuestionOrder.orderBoxes(boxes);
      expect(r.confidence, QuestionOrderConfidence.low);
      expect(r.reasons.any((s) => s.contains('栏数不一致')), isTrue);
    });

    test('跨栏块 → low：一个宽框越过栏界两侧各超 0.005', () {
      // 左右两栏（栏界 x≈0.5）+ 一个横跨的窄高框（高 0.04，
      // y 覆盖 0.04 < maxCover 0.05，不会把栏间隙填满）。
      final boxes = [
        _box(id: 'left', x: 0.05, y: 0.1, w: 0.35, h: 0.15),
        _box(id: 'right', x: 0.60, y: 0.1, w: 0.35, h: 0.15),
        _box(id: 'span', x: 0.30, y: 0.5, w: 0.40, h: 0.04),
      ];
      final r = QuestionOrder.orderBoxes(boxes);
      expect(r.confidence, QuestionOrderConfidence.low);
      expect(r.reasons.any((s) => s.contains('跨栏块')), isTrue);
      expect(r.reasons.any((s) => s.contains('span')), isTrue);
    });

    test('含糊重叠 → low：两框 x、y 都重叠，上缘差 <0.008 且 x 重叠 > 较窄框宽一半', () {
      final boxes = [
        _box(id: 'a', x: 0.1, y: 0.1, w: 0.4, h: 0.3),
        _box(id: 'b', x: 0.15, y: 0.105, w: 0.4, h: 0.3),
      ];
      final r = QuestionOrder.orderBoxes(boxes);
      expect(r.confidence, QuestionOrderConfidence.low);
      expect(r.reasons.any((s) => s.contains('含糊重叠')), isTrue);
    });

    test('回退但上缘分得清 → high：两框 y 向轻微重叠进回退组，上缘差远大于 0.008', () {
      // 两框 x、y 都重叠、无干净切分（进回退组），但上缘差 0.2，
      // (y_top, x_left) 顺序可靠，保持 high。
      final boxes = [
        _box(id: 'a', x: 0.1, y: 0.1, w: 0.4, h: 0.3),
        _box(id: 'b', x: 0.15, y: 0.3, w: 0.4, h: 0.3),
      ];
      final r = QuestionOrder.orderBoxes(boxes);
      expect(r.confidence, QuestionOrderConfidence.high);
      expect(r.reasons, isEmpty);
      expect(r.boxes.map((b) => b.id).toList(), ['a', 'b']);
    });
  });

  group('边界', () {
    test('空列表：原样返回空、high', () {
      final r = QuestionOrder.orderBoxes([]);
      expect(r.boxes, isEmpty);
      expect(r.confidence, QuestionOrderConfidence.high);
      expect(r.reasons, isEmpty);
    });

    test('单框：原样返回、high', () {
      final box = _box(id: 'only', x: 0.2, y: 0.3, w: 0.4, h: 0.2);
      final r = QuestionOrder.orderBoxes([box]);
      expect(r.boxes, [box]);
      expect(r.confidence, QuestionOrderConfidence.high);
      expect(r.reasons, isEmpty);
    });
  });
}
