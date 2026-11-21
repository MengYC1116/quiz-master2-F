// 十五批 M1-B：导出路由判定 + 50 道上限选择接口（M1-DESIGN.md §2/§5，
// C-1/C-2/C-8/D-175）。
//
// 路由判定：点「生成」后读一次 `OcrKeyStore.hasApiKey()`（只读有无，
// 不读 key 本身）。有 key → C（OCR 重排路线），无 key → 整单 A
// （图片增强路线）。读状态抛错 → 整单失败并明确报错，不得静默按
// 任一路线继续。路由在快照创建时冻结；生成中途 key 变化不切换路线。
//
// 50 道上限（§2 六处设防中的第 1 点，接口由 M1-B 定义、M3 实现）：
// 选中集合最大 50；全选 = 圈定范围的前 50 道（按 filteredAll() 顺序）
// + 明确提示。任何一处都不得静默截断。
import '../ocr_key_store.dart';

/// 导出路线：C = OCR 重排路线，A = 图片增强路线。
enum ExportRoute {
  /// OCR 重排路线（已配置 OCR key）。
  c,

  /// 图片增强路线（未配置 OCR key）。
  a;

  /// 路线中文名。
  String get label => switch (this) {
        ExportRoute.c => 'OCR 重排路线',
        ExportRoute.a => '图片增强路线',
      };
}

/// 单次导出硬上限（C-1，Meng 2026-11-20 21:49 定）。
const int kExportMaxQuestions = 50;

/// 路由判定失败：读 OCR key 状态抛错（整单失败，见 C-8）。
class RouteResolutionException implements Exception {
  RouteResolutionException(this.message);

  /// 面向用户的明确报错（不含 key 本身，不含安全存储原始报错文本）。
  final String message;

  @override
  String toString() => 'RouteResolutionException: $message';
}

/// 路由判定结果（纯数据）：本次路线 + 原因 + 面板明示文案。
class ExportRouteDecision {
  const ExportRouteDecision({required this.route, required this.reason});

  /// 本次路线（快照创建时冻结）。
  final ExportRoute route;

  /// 路由原因（供面板与完成界面明示）。
  final String reason;

  /// 面板与完成界面始终明示的本次路线文案（§5，两段文案原文）。
  String get notice => switch (route) {
        ExportRoute.c => '本次走 OCR 重排路线（已配置 OCR key）。'
            '本次不会自动补跑 OCR；没有 OCR 结果的题将被跳过，'
            '可去详情页重新触发 OCR。',
        ExportRoute.a => '本次走图片增强路线（未配置 OCR key）。'
            '去设置页配置 OCR key 可改走 OCR 重排路线（只提示，不强制跳转）。',
      };
}

/// 路由判定：读一次 key 状态（只读有无，不读 key）。
///
/// [hasApiKey] 由调用方传入（生产传 `OcrKeyStore.hasApiKey`，测试传
/// 桩函数）。判定失败（读状态抛错）→ 抛 [RouteResolutionException]，
/// 不得静默按任一路线继续。
Future<ExportRouteDecision> resolveExportRoute({
  required Future<bool> Function() hasApiKey,
}) async {
  late final bool hasKey;
  try {
    hasKey = await hasApiKey();
  } catch (e) {
    throw RouteResolutionException(
      '读取 OCR key 状态失败，无法确定导出路线'
      '（${e.runtimeType}），请稍后重试。',
    );
  }
  return ExportRouteDecision(
    route: hasKey ? ExportRoute.c : ExportRoute.a,
    reason: hasKey ? '已配置 OCR key' : '未配置 OCR key',
  );
}

/// 路由判定的生产入口：从 [OcrKeyStore] 读 key 状态。
Future<ExportRouteDecision> resolveExportRouteFromStore(
  OcrKeyStore keyStore,
) =>
    resolveExportRoute(hasApiKey: keyStore.hasApiKey);

// ------------------------------------------------------------------
// 50 道上限：选择状态接口（§2 第 1 点，M1-B 定义；十六批 B 起由列表页直接勾选使用，D-190）。
// ------------------------------------------------------------------

/// 全选提示语（已定，Meng 2026-11-20 22:35；Q2）。
/// “下次再导”的旧措辞作废——D-168 明确退出即丢弃选择、不保存导出历史。
String selectFirst50Notice(int totalCount) =>
    '范围共 $totalCount 道，已按当前排序选中前 50 道，'
    '其余题目未选中。你可以调整本次选择。';

/// 选中集合的上限检查结果（纯数据）。
class SelectionCapResult {
  const SelectionCapResult({required this.allowed, this.reason});

  /// 是否允许（选中数 ≤ 50）。
  final bool allowed;

  /// 超限拒绝原因（allowed 为 false 时非空；M3 展示用）。
  final String? reason;
}

/// 50 道上限检查（§2 第 1 点）：选中集合最大 50，超限拒绝。
SelectionCapResult checkSelectionCap(List<String> selectedIds) {
  if (selectedIds.length > kExportMaxQuestions) {
    return const SelectionCapResult(
      allowed: false,
      reason: '单次最多导出 50 道题',
    );
  }
  return const SelectionCapResult(allowed: true);
}

/// 全选 = 圈定范围的前 50 道（按 [rangeIds] 顺序，即 filteredAll() 顺序）
///
/// 返回选中 ID + 明示文案。只选前 50 道，不得把其余题目放进隐藏待导出
/// 队列；用户已手动选部分题再点全选 = 替换为当前范围排序前 50 道。
({List<String> selectedIds, String notice}) selectFirst50(
  List<String> rangeIds,
) {
  final selected = rangeIds.take(kExportMaxQuestions).toList();
  return (
    selectedIds: selected,
    notice: selectFirst50Notice(rangeIds.length),
  );
}
