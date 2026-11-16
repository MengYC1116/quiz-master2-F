// B11-2：批量导入队列卡片（纯展示组件，状态来自 BatchImportState）。
//
// 放在收集中心任务列表上方：标题行（已完成 x / n · 失败数）+ 总进度
// 条 + 每行一个文件（名、状态、导入中进度条、失败原因、建议试卷名、
// 失败行的“重试”）+ 底部“重试失败项 / 关闭”。
// 单文件导入不建队列、不显示本卡片（见 CollectPage._importFiles）。
import 'package:flutter/material.dart';

import '../../theme/design_tokens.dart';
import '../../widgets/uikit.dart';
import 'batch_import.dart';

/// 批量导入队列卡片。
class BatchImportCard extends StatelessWidget {
  const BatchImportCard({
    super.key,
    required this.batch,
    required this.onRetryFailed,
    required this.onRetryPath,
    required this.onDismiss,
  });

  final BatchImportState batch;

  /// “重试失败项”（全部失败行重导）。
  final VoidCallback onRetryFailed;

  /// 单行“重试”（只重导这一行）。
  final ValueChanged<String> onRetryPath;

  /// “关闭”（只关卡片，不删任务）。
  final VoidCallback onDismiss;

  static String _statusText(BatchImportFile file) => switch (file.status) {
    BatchFileStatus.queued => '排队中',
    BatchFileStatus.importing => '导入中 ${file.progress}%',
    BatchFileStatus.done => '已完成',
    BatchFileStatus.failed => '失败',
  };

  @override
  Widget build(BuildContext context) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    final done = batch.doneCount;
    final total = batch.total;
    return Container(
      key: const Key('batch-import-card'),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border.all(color: palette.line),
        borderRadius: BorderRadius.circular(
          DesignTokens.scaled(scale).radiusLg,
        ),
      ),
      padding: EdgeInsets.all(14 * scale),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '批量导入 · ${batch.summary}',
                  style: TextStyle(
                    fontSize: DesignTokens.bodyFontSize,
                    fontWeight: FontWeight.w700,
                    color: palette.ink,
                    height: 1.3,
                  ),
                ),
              ),
              if (batch.isFinished)
                QmButton(
                  key: const Key('batch-dismiss'),
                  label: '关闭',
                  variant: QmButtonVariant.plain,
                  size: QmButtonSize.small,
                  onPressed: onDismiss,
                ),
            ],
          ),
          SizedBox(height: 8 * scale),
          ClipRRect(
            borderRadius: BorderRadius.circular(99 * scale),
            child: LinearProgressIndicator(
              value: total == 0 ? 0 : done / total,
              minHeight: 8 * scale,
              backgroundColor: palette.surface3,
              valueColor: AlwaysStoppedAnimation<Color>(palette.accent),
            ),
          ),
          SizedBox(height: 4 * scale),
          Text(
            batch.isFinished
                ? (batch.hasFailures ? '失败的可以重试，其他文件不受影响。' : '都导完了，去修框吧。')
                : '一个一个导，失败的不影响其他文件。',
            style: TextStyle(
              fontSize: DesignTokens.bodySmallFontSize,
              color: palette.muted,
              height: 1.4,
            ),
          ),
          SizedBox(height: 6 * scale),
          for (var i = 0; i < batch.files.length; i++)
            _BatchRow(
              file: batch.files[i],
              index: i,
              scale: scale,
              palette: palette,
              onRetryPath: onRetryPath,
            ),
          if (batch.hasFailures && batch.isFinished) ...[
            SizedBox(height: 10 * scale),
            QmButton(
              key: const Key('batch-retry-all'),
              label: '重试失败项（${batch.failedCount} 个）',
              variant: QmButtonVariant.primary,
              size: QmButtonSize.small,
              onPressed: onRetryFailed,
            ),
          ],
        ],
      ),
    );
  }
}

class _BatchRow extends StatelessWidget {
  const _BatchRow({
    required this.file,
    required this.index,
    required this.scale,
    required this.palette,
    required this.onRetryPath,
  });

  final BatchImportFile file;
  final int index;
  final double scale;
  final AppPalette palette;
  final ValueChanged<String> onRetryPath;

  @override
  Widget build(BuildContext context) {
    final failed = file.status == BatchFileStatus.failed;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4 * scale),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      style: TextStyle(
                        fontSize: DesignTokens.bodyFontSize,
                        fontWeight: FontWeight.w700,
                        color: palette.ink,
                        height: 1.3,
                      ),
                    ),
                    Text(
                      [
                        BatchImportCard._statusText(file),
                        if (file.guessedExam != null)
                          '建议试卷：${file.guessedExam}',
                      ].join(' · '),
                      style: TextStyle(
                        fontSize: DesignTokens.bodySmallFontSize,
                        color: failed ? palette.errInk : palette.muted,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              if (failed)
                QmButton(
                  key: Key('batch-retry-$index'),
                  label: '重试',
                  variant: QmButtonVariant.plain,
                  size: QmButtonSize.small,
                  onPressed: () => onRetryPath(file.path),
                ),
            ],
          ),
          if (file.status == BatchFileStatus.importing) ...[
            SizedBox(height: 6 * scale),
            ClipRRect(
              borderRadius: BorderRadius.circular(99 * scale),
              child: LinearProgressIndicator(
                value: file.progress / 100,
                minHeight: 6 * scale,
                backgroundColor: palette.surface3,
                valueColor: AlwaysStoppedAnimation<Color>(palette.accent),
              ),
            ),
          ],
          if (failed && file.error != null) ...[
            SizedBox(height: 2 * scale),
            Text(
              file.error!,
              style: TextStyle(
                fontSize: DesignTokens.bodySmallFontSize,
                color: palette.errInk,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
