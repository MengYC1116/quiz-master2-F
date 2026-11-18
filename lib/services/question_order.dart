// 题序：XY-cut 混合排序（十二批功能 8 Stage B，D-96）。
//
// Stage A 离线脚本 `~/workspace/batch12-work/stage-a/xy_cut.py` 的 Dart
// 移植，常量与语义与脚本一字不差，唯一改动是把 Python 的 dict / 元组换
// 成 Dart 的 record / 小类。验证结论见
// `~/workspace/batch12-work/STAGE-A-REPORT.md`：
// 30 页框齐全页上全页完全正确率 30/30，朴素 y-then-x 只有 8/30。
//
// 算法三段：栏结构检测优先（x 投影 + 区间链接交叉校验）→ 栏内递归
// XY-cut → 低置信度退化人工（只标 flag，不伪装确定；见 D-96 §7(5)）。
//
// 诚实说明（Stage A §5.3）：本样本上 XY-cut 与“栏检测 + 栏内 y 排序”
// 并列 30/30；真正修掉触发 bug 的是栏检测，不是 XY-cut 本身。
// XY-cut 的价值在栏内不规则排布（本样本零实例）与置信度机制。
// 仍用 XY-cut 混合的理由：规则版式上与 y 排序等价，不规则版式上
// 更一般，且置信度机制是同一套。
//
// 局限（Stage A §6，Stage B 带着这些做）：
// - 样本全是规则版式，栏内并排/交错零实例，XY-cut 在这些情况上未经
//   验证——低置信度页必须保留转人工路径（编辑器横幅提醒核对）。
// - 第 4 类跨栏（题干右、配图左）本样本 0 例，纯几何处理不了：算法
//   会把配图排到题干前面；遇上只能靠用户在编辑器里手动调框。
// - 含糊阈值 ambigTop = 0.008 是看数据后定的（样本最小上缘差 0.010）；
//   0% 转人工率是“本样本 + 本阈值”的结果，不是算法的固有属性，
//   不要在代码注释或 UI 里宣称算法“100% 准确”。
// - 检测问题（漏检/误检/重叠框）是检测的事，本服务只解决“框的顺序”，
//   不解决“框的质量”。
import '../models/models.dart';

/// 题序置信度：high = 算法敢认这个顺序；low = 几何上拿不准，
// 请人工核对（编辑器出横幅，框仍按算法顺序编号展示，不伪装确定）。
enum QuestionOrderConfidence { high, low }

/// [QuestionOrder.orderBoxes] 的结果：阅读顺序的框 + 置信度。
class QuestionOrderResult {
  const QuestionOrderResult({
    required this.boxes,
    required this.confidence,
    required this.reasons,
  });

  /// 阅读顺序的框（与输入同一批对象，只换顺序，不改坐标）。
  final List<QuestionBox> boxes;

  final QuestionOrderConfidence confidence;

  /// 置信度低的原因（high 时为空，只记“为什么低”，不记过程笔记）。
  final List<String> reasons;
}

/// XY-cut 混合排序（纯函数，无 IO，可单测）：
///
/// - 0/1 个框：原样返回，high。
/// - 多栏：栏检测（x 投影找栏间空白 + 区间链接交叉校验）→ 每栏内
///   递归 XY-cut → 栏按左→右拼；延续框（题干在左栏、选项/配图在
///   右栏）自动紧跟题干——延续在下一栏顶部时，其题干必然是本栏
///   最后一框（跨栏定义见 Stage A 报告 §3.2，Meng 2026-11-18 确认：
///   位置按题干开头定，其他部分不单独占排序位置）。
class QuestionOrder {
  /// 栏间空白的最小宽度（占页宽的比例；脚本 MIN_GAP_W）。
  static const double minGapW = 0.004;

  /// 栏间空白内允许的最大 y 覆盖率（脚本 MAX_COVER）。
  static const double maxCover = 0.05;

  /// XY-cut 接受的最小切分间隙（脚本 MIN_CUT_GAP；1px 干净分隔仍是
  /// 有效切分，切分只分区、不重排）。
  static const double minCutGap = 0.0005;

  /// 区间链接交叉校验的容差（脚本 CHAIN_TOL）。
  static const double chainTol = 0.003;

  /// 含糊阈值（脚本 AMBIG_TOP）：回退组里两框上缘差小于此值（1200px
  /// 页上约 10px，人眼可辨的下限）且 x 重叠超一半时，顺序真拿不准。
  static const double ambigTop = 0.008;

  /// 含糊阈值（脚本 AMBIG_XOVERLAP）：x 重叠占较窄框宽的比例。
  static const double ambigXOverlap = 0.5;

  /// 跨栏块判定（脚本 SPAN_TOL）：框越过栏界超过此值才算跨栏块。
  static const double spanTol = 0.005;

  /// x 投影的分辨率（脚本 BINS）。
  static const int projectionBins = 1000;

  /// 对一页的框排出人阅读顺序（纯函数；不改框，只换顺序）。
  static QuestionOrderResult orderBoxes(List<QuestionBox> boxes) {
    if (boxes.length <= 1) {
      return QuestionOrderResult(
        boxes: List.of(boxes),
        confidence: QuestionOrderConfidence.high,
        reasons: const [],
      );
    }
    final boundaries = _detectColumns(boxes);
    final nGapCols = boundaries.length + 1;
    final nChainCols = _chainColumns(boxes);
    final reasons = <String>[];
    var confidence = QuestionOrderConfidence.high;
    if (nGapCols != nChainCols) {
      confidence = QuestionOrderConfidence.low;
      reasons.add('栏数不一致：投影法 $nGapCols 栏，区间链接法 $nChainCols 栏');
    }
    final (cols, spanning) = _assignColumns(boxes, boundaries);
    if (spanning.isNotEmpty) {
      confidence = QuestionOrderConfidence.low;
      reasons.add('${spanning.length} 个跨栏块：${spanning.map((b) => b.id).join('、')}');
    }
    final state = _XyState();
    final ordered = <QuestionBox>[];
    for (var ci = 0; ci < nGapCols; ci++) {
      final colBoxes = <QuestionBox>[];
      for (var i = 0; i < boxes.length; i++) {
        if (cols[i] == ci) colBoxes.add(boxes[i]);
      }
      ordered.addAll(_xyOrder(colBoxes, state));
    }
    if (state.fallbackList.isNotEmpty) {
      final ambiguous = <(String, String)>[];
      for (final group in state.fallbackList) {
        final pair = _ambiguousPair(group);
        if (pair != null) ambiguous.add(pair);
      }
      if (ambiguous.isNotEmpty) {
        confidence = QuestionOrderConfidence.low;
        reasons.add(
          '含糊重叠（上缘接近）：${ambiguous.map((p) => '${p.$1} 与 ${p.$2}').join('、')}',
        );
      }
    }
    var finalOrdered = ordered;
    if (spanning.isNotEmpty) {
      // 跨栏块：独立版面块，按上缘定位置，与栏内顺序合并后按
      // (y_top, x_left) 排。样本里没有跨栏块（见 Stage A 报告 §4.1），
      // 这只是回退路径。
      final merged = [...ordered, ...spanning];
      merged.sort((a, b) {
        final dy = a.y.compareTo(b.y);
        return dy != 0 ? dy : a.x.compareTo(b.x);
      });
      finalOrdered = merged;
    }
    return QuestionOrderResult(
      boxes: finalOrdered,
      confidence: confidence,
      reasons: reasons,
    );
  }

  /// x 投影找栏间空白（脚本 detect_columns）：
///
/// 每列 bin 算 y 覆盖率（与该列横向相交的框的 y 并集 / 页高）；
/// 覆盖率 < maxCover 且宽 ≥ minGapW 的连续 bin 段是候选栏间隙；
/// 两侧都有框的间隙才算栏界，栏界取间隙中点。返回栏界 x 坐标（升序）。
  static List<double> _detectColumns(List<QuestionBox> boxes) {
    final cov = List<double>.filled(projectionBins, 0.0);
    for (var i = 0; i < projectionBins; i++) {
      cov[i] = _yCoverage(boxes, i / projectionBins, (i + 1) / projectionBins);
    }
    final gaps = <(double, double)>[];
    var i = 0;
    while (i < projectionBins) {
      if (cov[i] < maxCover) {
        var j = i;
        while (j < projectionBins && cov[j] < maxCover) {
          j++;
        }
        final width = (j - i) / projectionBins;
        if (width >= minGapW) gaps.add((i / projectionBins, j / projectionBins));
        i = j;
      } else {
        i++;
      }
    }
    var minX = double.infinity;
    var maxX = double.negativeInfinity;
    for (final b in boxes) {
      if (b.x < minX) minX = b.x;
      if (b.x + b.w > maxX) maxX = b.x + b.w;
    }
    final boundaries = <double>[];
    for (final (g0, g1) in gaps) {
      if (minX < g0 && maxX > g1) boundaries.add((g0 + g1) / 2.0);
    }
    boundaries.sort();
    return boundaries;
  }

  /// [x0, x1] 列上被框覆盖的 y 比例（脚本 _y_coverage）：与该列横向
  /// 相交的框的 y 区间求并集，再除以页高（页高归一化为 1）。
  static double _yCoverage(List<QuestionBox> boxes, double x0, double x1) {
    final intervals = <(double, double)>[];
    for (final b in boxes) {
      if (b.x < x1 && b.x + b.w > x0) {
        intervals.add((b.y, b.y + b.h));
      }
    }
    if (intervals.isEmpty) return 0.0;
    intervals.sort((a, b) => a.$1.compareTo(b.$1));
    var total = 0.0;
    var cs = intervals[0].$1;
    var ce = intervals[0].$2;
    for (var k = 1; k < intervals.length; k++) {
      final (s, e) = intervals[k];
      if (s > ce) {
        total += ce - cs;
        cs = s;
        ce = e;
      } else if (e > ce) {
        ce = e;
      }
    }
    total += ce - cs;
    return total.clamp(0.0, 1.0);
  }

  /// 区间链接交叉校验（脚本 chain_columns）：按 x 区间分组，相交
  /// （容差 chainTol）即连成一组；窄框/宽窄悬殊的框不会像中心聚类
  /// 那样拉偏栏数（Stage A 第一版的 3 处误判全是中心聚类惹的）。
  static int _chainColumns(List<QuestionBox> boxes) {
    final intervals = boxes.map((b) => (b.x, b.x + b.w)).toList()
      ..sort((a, b) => a.$1.compareTo(b.$1));
    var n = 1;
    var curEnd = intervals[0].$2;
    for (var k = 1; k < intervals.length; k++) {
      final (s, e) = intervals[k];
      if (s <= curEnd + chainTol) {
        if (e > curEnd) curEnd = e;
      } else {
        n++;
        curEnd = e;
      }
    }
    return n;
  }

  /// 每框分栏（脚本 assign_columns）：越过栏界超 spanTol 的框是跨栏块
  /// （分栏记 null），其余按中心点落在第几个栏界右侧分栏。
  static (List<int?>, List<QuestionBox>) _assignColumns(
    List<QuestionBox> boxes,
    List<double> boundaries,
  ) {
    final cols = <int?>[];
    final spanning = <QuestionBox>[];
    for (final b in boxes) {
      final x0 = b.x;
      final x1 = b.x + b.w;
      final crosses = boundaries.any(
        (bd) => x0 < bd - spanTol && x1 > bd + spanTol,
      );
      if (crosses) {
        spanning.add(b);
        cols.add(null);
        continue;
      }
      final cx = b.x + b.w / 2.0;
      cols.add(boundaries.where((bd) => cx > bd).length);
    }
    return (cols, spanning);
  }

  /// 栏内递归 XY-cut（脚本 xy_order）：水平切优先（切线不穿过任何框、
  /// 间隙 ≥ minCutGap、两侧非空、取最大间隙）；无水平切则试垂直切；
  /// 两者皆无（框在两个方向都重叠）→ 局部 (y_top, x_left) 排序并记
  /// 回退组（回退本身不等于低置信度，见 [_ambiguousPair]）。
  static List<QuestionBox> _xyOrder(
    List<QuestionBox> boxes,
    _XyState state,
  ) {
    if (boxes.length <= 1) return List.of(boxes);
    final h = _bestHCut(boxes);
    final v = _bestVCut(boxes);
    // 取较大干净间隙；水平切赢平局（阅读顺序）。
    if (h != null && (v == null || h.gap >= v.gap)) {
      return [..._xyOrder(h.top, state), ..._xyOrder(h.bottom, state)];
    }
    if (v != null) {
      return [..._xyOrder(v.left, state), ..._xyOrder(v.right, state)];
    }
    state.fallbackList.add(List.of(boxes));
    final sorted = List.of(boxes)
      ..sort((a, b) {
        final dy = a.y.compareTo(b.y);
        return dy != 0 ? dy : a.x.compareTo(b.x);
      });
    return sorted;
  }

  /// 最大干净水平间隙（脚本 _best_h_cut）：候选切线取全部框的上缘/
  /// 下缘；切线上下两侧非空、且每个框都完整落在某一侧（切线不穿框）。
  static ({double gap, List<QuestionBox> top, List<QuestionBox> bottom})?
  _bestHCut(List<QuestionBox> boxes) {
    final ys = <double>{
      for (final b in boxes) ...[b.y, b.y + b.h],
    }.toList()
      ..sort();
    ({double gap, List<QuestionBox> top, List<QuestionBox> bottom})? best;
    for (final y in ys) {
      final top = boxes.where((b) => b.y + b.h <= y + 1e-9).toList();
      final bot = boxes.where((b) => b.y >= y - 1e-9).toList();
      if (top.isEmpty || bot.isEmpty) continue;
      if (top.length + bot.length != boxes.length) continue;
      final gap =
          bot.map((b) => b.y).reduce((a, b) => a < b ? a : b) -
          top.map((b) => b.y + b.h).reduce((a, b) => a > b ? a : b);
      if (gap >= minCutGap && (best == null || gap > best.gap)) {
        best = (gap: gap, top: top, bottom: bot);
      }
    }
    return best;
  }

  /// 最大干净垂直间隙（脚本 _best_v_cut），与 [_bestHCut] 对称。
  static ({double gap, List<QuestionBox> left, List<QuestionBox> right})?
  _bestVCut(List<QuestionBox> boxes) {
    final xs = <double>{
      for (final b in boxes) ...[b.x, b.x + b.w],
    }.toList()
      ..sort();
    ({double gap, List<QuestionBox> left, List<QuestionBox> right})? best;
    for (final x in xs) {
      final left = boxes.where((b) => b.x + b.w <= x + 1e-9).toList();
      final right = boxes.where((b) => b.x >= x - 1e-9).toList();
      if (left.isEmpty || right.isEmpty) continue;
      if (left.length + right.length != boxes.length) continue;
      final gap =
          right.map((b) => b.x).reduce((a, b) => a < b ? a : b) -
          left.map((b) => b.x + b.w).reduce((a, b) => a > b ? a : b);
      if (gap >= minCutGap && (best == null || gap > best.gap)) {
        best = (gap: gap, left: left, right: right);
      }
    }
    return best;
  }

  /// 回退组里是否有一对真正含糊的框（脚本 _ambiguous_pair）：上缘差
  /// < ambigTop 且 x 重叠 > 较窄框宽的一半——人眼也分不出先后，顺序
  /// 不能只靠几何定。上缘分得清时 (y_top, x_left) 顺序可靠，保持 high。
  static (String, String)? _ambiguousPair(List<QuestionBox> group) {
    for (var i = 0; i < group.length; i++) {
      for (var j = i + 1; j < group.length; j++) {
        final a = group[i];
        final b = group[j];
        if ((a.y - b.y).abs() >= ambigTop) continue;
        final overlapX =
            (a.x + a.w < b.x + b.w ? a.x + a.w : b.x + b.w) -
            (a.x > b.x ? a.x : b.x);
        final narrower = a.w < b.w ? a.w : b.w;
        if (overlapX > ambigXOverlap * narrower) return (a.id, b.id);
      }
    }
    return null;
  }
}

/// [_QuestionOrder._xyOrder] 的回退记录：每次局部排序都记一组，
// 调用方只在组里出现真正含糊的一对时才标低置信度。
class _XyState {
  final List<List<QuestionBox>> fallbackList = [];
}
