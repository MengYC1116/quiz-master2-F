import '../models/models.dart';

/// YOLO 两层检测（ONNX）。
/// 层 1 = 整题框 → 整题切片；层 2 = 题干 / 选项 / 配图辅助区，
/// 永不产生单独题目，永不加公式 / 题号类别。
/// 本文件为占位实现：先用规则框（整页一个整题框）跑通收集 → 整理链路，
/// 真模型 `best.onnx`（约 37 MB）到位后在此处接 onnxruntime，
/// 见 docs/decision-log.md D-07。
class YoloOnnxService {
  YoloOnnxService({this.modelAsset = 'assets/models/best.onnx'});

  /// ONNX 模型路径（安装目录 / assets）。占位模式下文件不存在也照常工作。
  final String modelAsset;

  /// 是否已加载真模型。占位模式为 false。
  bool get hasRealModel => false;

  /// 对一页做两层检测。占位：返回一个覆盖页面的整题框。
  Future<List<QuestionBox>> detectPage({
    required String imagePath,
    required int page,
  }) async {
    // TODO(D-07): 接 onnxruntime，加载 best.onnx，输入页图，输出两层框。
    // 层 1 整题框；层 2 仅 stem / option / figure，且必须落在所属整题框内。
    return [
      const QuestionBox(
          id: 'box-q1', layer: 1, type: 'question', x: 0.06, y: 0.05, w: 0.88, h: 0.85),
    ];
  }

  /// 框钳制：框不得超出页面（0..1），新画的框同样钳制；尺寸随图片实际大小走。
  static QuestionBox clampToPage(QuestionBox box) {
    final x = box.x.clamp(0.0, 1.0);
    final y = box.y.clamp(0.0, 1.0);
    final w = box.w.clamp(0.08, 1.0 - x);
    final h = box.h.clamp(0.08, 1.0 - y);
    return QuestionBox(
        id: box.id, layer: box.layer, type: box.type, x: x, y: y, w: w, h: h);
  }
}
