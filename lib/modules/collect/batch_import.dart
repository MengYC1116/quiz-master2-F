// B11-2：批量导入队列的状态模型（纯 Dart，可单元测试）。
//
// 一批文件逐个处理：每行一个文件，状态 排队中 → 导入中 → 已完成 /
// 失败；单张失败只影响本行，不中断整批；失败行可单独重试，也可
// “重试全部失败项”。队列本身不跑导入，只记状态——导入循环在
// CollectNotifier.importFiles 里按现有 enqueue 逐个调。
enum BatchFileStatus { queued, importing, done, failed }

/// 队列里的一行。
class BatchImportFile {
  BatchImportFile({required this.path, required this.name, this.guessedExam});

  /// 源文件绝对路径（重试时按它重导）。
  final String path;

  /// 显示名（文件名）。
  final String name;

  /// 按文件名猜的试卷名（只做行上建议显示，不写库）。
  final String? guessedExam;

  BatchFileStatus status = BatchFileStatus.queued;

  /// 导入中 0..100（复制 / 渲染进度，与任务行同一口径）。
  int progress = 0;

  /// 失败原因（与失败任务的 error 同文案）。
  String? error;
}

/// 一批导入的队列状态。
class BatchImportState {
  BatchImportState({required this.subjectId, required this._files});

  /// 本批的学科（重试失败项时沿用，不重新猜）。
  final String subjectId;

  final List<BatchImportFile> _files;

  List<BatchImportFile> get files => List.unmodifiable(_files);

  int get total => _files.length;

  int get doneCount =>
      _files.where((f) => f.status == BatchFileStatus.done).length;

  int get failedCount =>
      _files.where((f) => f.status == BatchFileStatus.failed).length;

  /// 已出结果（完成 + 失败）的行数。
  int get finishedCount => doneCount + failedCount;

  /// 全部行都已出结果（完成或失败）。
  bool get isFinished => _files.isNotEmpty && finishedCount == total;

  bool get hasFailures => failedCount > 0;

  /// 失败行的源文件路径（重试用）。
  List<String> get failedPaths => [
    for (final f in _files)
      if (f.status == BatchFileStatus.failed) f.path,
  ];

  int indexOfPath(String path) => _files.indexWhere((f) => f.path == path);

  void markImporting(int index) {
    final file = _files[index];
    file.status = BatchFileStatus.importing;
    file.progress = 0;
    file.error = null;
  }

  void markProgress(int index, int progress) {
    _files[index].progress = progress.clamp(0, 100);
  }

  void markDone(int index) {
    final file = _files[index];
    file.status = BatchFileStatus.done;
    file.progress = 100;
    file.error = null;
  }

  void markFailed(int index, String error) {
    final file = _files[index];
    file.status = BatchFileStatus.failed;
    file.progress = 0;
    file.error = error;
  }

  /// 重试前把失败行打回排队中（进度与错误清空）。
  void resetForRetry(int index) {
    final file = _files[index];
    file.status = BatchFileStatus.queued;
    file.progress = 0;
    file.error = null;
  }

  /// 卡片标题行：`已完成 2 / 5 · 1 个失败`。
  String get summary {
    final base = '已完成 $doneCount / $total';
    if (failedCount == 0) return base;
    return '$base · $failedCount 个失败';
  }
}
