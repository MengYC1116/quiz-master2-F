// 十五批 M1-B：快照失败分类（M1-DESIGN.md §6，D-179，REV2 统一口径）。
//
// - 源数据缺失/损坏/无法解码（源文件本身问题，复制前即发现）→
//   题目级处理（C：跳过 + 警告；A：BROKEN 占位 + 警告），继续导出。
//   本文件不为它设整单异常（数据源以 null / SliceUnavailableException /
//   SliceSourceCorruptException 在题目级报告，见
//   export_question_record.dart / slice_snapshot.dart）。
// - 已成功创建的快照副本哈希不一致 → 快照完整性失败，中止本次任务
//   并清理临时目录，不得伪装成单题问题后继续生成。
// - 任务临时目录写入失败、磁盘满、权限不足 → 快照基础设施失败，
//   中止本次任务并清理临时目录，不得伪装成单题问题后继续生成。
// - 快照期间源内容变化（终态复核发现哈希/版本变化）→ 整单失效，
//   清理临时目录，明确报错“快照期间题目内容发生变化，请重试”（D-178）。

/// 快照期间题目内容发生变化（D-178 终态复核）：整单失效。
class SnapshotChangedException implements Exception {
  SnapshotChangedException([this.message = '快照期间题目内容发生变化，请重试']);

  /// 面向用户的明确报错（固定文案，见 §6）。
  final String message;

  @override
  String toString() => 'SnapshotChangedException: $message';
}

/// 已成功创建的快照副本哈希不一致（D-179）：整单中止。
class SnapshotIntegrityException implements Exception {
  SnapshotIntegrityException(this.message);

  final String message;

  @override
  String toString() => 'SnapshotIntegrityException: $message';
}

/// 任务临时目录写入失败 / 磁盘满 / 权限不足（D-179）：整单中止。
class SnapshotInfrastructureException implements Exception {
  SnapshotInfrastructureException(this.message);

  final String message;

  @override
  String toString() => 'SnapshotInfrastructureException: $message';
}
