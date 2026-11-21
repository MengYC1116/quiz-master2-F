// 十五批 M3：导出流程控制器（PLAN-15-REV3 §6 M3-2；M1-DESIGN.md §2）。
//
// 确认步（界面）与生成/交付（服务）之间的编排层：
// - 盘点 → 生成（PDF 两版，同一快照；Word 单份，练习版与答案版在同一
//   份 .docx 内）→ 交付（PDF 逐份，P1-5 部分成功语义；Word 单份）；
// - 进度按题推进（服务侧 onProgress 回调：准备 / 公式栅格化按题报数，
//   Isolate 生成阶段报“正在生成 PDF…” / “正在生成 Word…”）；可取消
//   （ExportCancellationToken，取消即停、清理临时文件、不留半截文件；
//   C 路线栅格化取消由服务侧接 ExportCancellationToken →
//   FormulaRasterizer.cancel()，见 pdf_export_service.dart）；
// - 完成 / 部分成功 / 失败 / 取消四种终态全部以数据留在控制器里，
//   完成界面只做展示；导出不写数据库（快照在内存，报告在任务内），
//   不推进治愈、不记复习记录、不动最近查看、不动角标。
//
// 外部边界全部可注入（生产传真实服务，测试传桩）：控制器本身不直接
// 读库、不直接碰文件系统、不直接弹系统对话框。
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../word_export/word_export_service.dart';
import 'export_integrity.dart';
import 'export_inventory.dart';
import 'export_route.dart';
import 'export_snapshot.dart';
import 'export_versions.dart';
import 'pdf_delivery.dart';
import 'pdf_export_service.dart';

/// 盘点回调（生产：路由判定 + 读行 + runInventory；测试：桩）。
typedef ComputeInventoryFn =
    Future<ExportInventory> Function({
      required List<String> ids,
      required List<ExcludedQuestion> excluded,
      required int circledCount,
    });

/// 两版生成回调（生产：PdfExportService.generateVersions；测试：桩）。
///
/// [subjectName]/[folderName] 为本次范围的展示名（多学科时“多学科”，
/// 多文件夹时 null，由确认步在点「生成」时按最终范围传入；不得取第一道
/// 题的学科 / 文件夹代表范围）；[excludeLowDpi] 为面板勾选的
/// “排除低于清晰度阈值的题”。
typedef GenerateVersionsFn =
    Future<TwoVersionExportResult> Function({
      required List<String> ids,
      required List<ExcludedQuestion> excluded,
      required String filterText,
      required String sortText,
      required ExportVersionSelection versions,
      required int circledCount,
      required ExportCancellationToken token,
      void Function(int done, int total, String label)? onProgress,
      String subjectName,
      String? folderName,
      bool excludeLowDpi,
    });

/// 文件交付回调（生产：PdfDeliveryService.deliverAll；测试：桩）。
typedef DeliverAllFn =
    Future<List<FileDeliveryResult>> Function({
      required List<VersionDeliveryRequest> requests,
    });

/// Word 生成回调（生产：WordExportService.generateVersions；测试：桩）。
///
/// 与 [GenerateVersionsFn] 同输入，返回单份 Word 结果（练习版与答案版
/// 在同一份 .docx 内，不分版；答案版勾选时答案区追加在同一文件内）。
typedef GenerateWordFn =
    Future<WordExportResult> Function({
      required List<String> ids,
      required List<ExcludedQuestion> excluded,
      required String filterText,
      required String sortText,
      required ExportVersionSelection versions,
      required int circledCount,
      required ExportCancellationToken token,
      void Function(int done, int total, String label)? onProgress,
      String subjectName,
      String? folderName,
      bool excludeLowDpi,
    });

/// Word 文件交付回调（生产：WordDeliveryService.deliver；测试：桩）。
typedef DeliverWordFn =
    Future<FileDeliveryResult> Function({
      required Uint8List docxBytes,
      required String fileName,
      required int expectedImageCount,
    });

/// 导出流程阶段。
enum ExportFlowPhase {
  /// 未开始。
  idle,

  /// 正在盘点（确认步内容加载中）。
  preparing,

  /// 正在生成 PDF/Word（准备 / 栅格化 / Isolate 生成）。
  generating,

  /// 正在落盘交付（另存为对话框 / 写下载目录）。
  delivering,

  /// 完成（全部成功或部分成功——以 [deliveryResults] /
  /// [versionsResult] 逐份状态为准，不得把部分成功伪装成全部成功）。
  done,

  /// 整单失败（路由判定失败 / guard 硬拒绝 / 零可印 / 磁盘满 /
  /// 生成崩溃 / 验证失败等；失败后临时文件已清理，不留损坏文件）。
  failed,

  /// 用户取消（已停、已清理，不留半截 PDF）。
  cancelled,
}

/// 完成界面展示用的一份文件行（生成结果 + 交付结果拼成一行；
// 生成失败的版本只有生成错误，没有交付行）。
class ExportCompletionRow {
  const ExportCompletionRow({
    required this.version,
    required this.fileName,
    this.pageCount,
    this.questionCount,
    this.deliveredPath,
    this.generationError,
    this.deliveryError,
    this.labelOverride,
    this.isWordCombined = false,
    this.fileSizeBytes,
  });

  /// 版本。
  final ExportVersion version;

  /// 文件名（落盘后的实际文件名；生成失败时为期望文件名）。
  final String fileName;

  /// 页数（已交付时为验证通过的页数；Word 为 null——页数只有 Word
  /// 打开后才知道，完成界面写“以 Word 打开为准”，不得编造）。
  final int? pageCount;

  /// 题数（已生成时为该版题数）。
  final int? questionCount;

  /// 落盘后的完整路径（已交付时非空）。
  final String? deliveredPath;

  /// 生成失败原因（生成失败时非空）。
  final String? generationError;

  /// 交付失败原因（交付失败时非空）。
  final String? deliveryError;

  /// 完成界面显示的版本标签覆盖（Word 行显示 'Word'，不显示
  /// '练习版'；为 null 时显示 [version] 的 label）。
  final String? labelOverride;

  /// 是否 Word 合并文件（练习版与答案版在同一份 .docx 内；
  /// 为 true 时完成界面隐藏答案版文件名行，显示合并说明）。
  final bool isWordCombined;

  /// 文件字节数（Word 行展示用实际大小；PDF 行不用）。
  final int? fileSizeBytes;

  /// 是否已交付。
  bool get isDelivered => deliveredPath != null && deliveryError == null;

  /// 是否生成失败。
  bool get generationFailed => generationError != null;
}

/// 导出流程控制器：盘点 → 生成 → 交付 → 终态。
class ExportFlowController extends ChangeNotifier {
  ExportFlowController({
    required this.computeInventory,
    required this.generateVersions,
    required this.deliverAll,
    this.generateWord,
    this.deliverWord,
    this.openFile,
    this.openFolder,
    this.shareFile,
    this.platformOverride,
  });

  /// 盘点回调。
  final ComputeInventoryFn computeInventory;

  /// 两版生成回调。
  final GenerateVersionsFn generateVersions;

  /// 文件交付回调。
  final DeliverAllFn deliverAll;

  /// Word 生成回调（Word 格式时必需；PDF 格式时可不传）。
  final GenerateWordFn? generateWord;

  /// Word 文件交付回调（Word 格式时必需；PDF 格式时可不传）。
  final DeliverWordFn? deliverWord;

  /// 打开文件（生产：PdfDeliveryService.openPdf；测试：桩）。
  final Future<bool> Function(String path)? openFile;

  /// 打开所在文件夹（生产：PdfDeliveryService.openContainingFolder）。
  final Future<bool> Function(String path)? openFolder;

  /// 系统分享（生产：PdfDeliveryService.sharePdf）。
  final Future<ShareResult> Function(String path)? shareFile;

  /// 平台覆盖（仅测试用：Linux 测试机上模拟 Windows/Android 流程；
  /// 生产传 null，按真实平台分发）。
  final PdfDeliveryPlatform? platformOverride;

  /// 当前阶段。
  ExportFlowPhase _phase = ExportFlowPhase.idle;
  ExportFlowPhase get phase => _phase;

  /// 是否终态（完成 / 失败 / 取消）。
  bool get isTerminal =>
      _phase == ExportFlowPhase.done ||
      _phase == ExportFlowPhase.failed ||
      _phase == ExportFlowPhase.cancelled;

  /// 盘点结果（确认步内容；准备失败时为 null）。
  ExportInventory? inventory;

  /// 两版生成结果（生成成功后非空；两版都失败时为 null，见
  /// [error]）。
  TwoVersionExportResult? versionsResult;

  /// Word 生成结果（Word 格式生成成功后非空；与 [versionsResult]
  /// 二选一，Word 不用两版结果）。
  WordExportResult? wordResult;

  /// 每份文件的交付结果（交付阶段后非空，按版本顺序）。
  List<FileDeliveryResult>? deliveryResults;

  /// Word 文件的交付结果（Word 格式交付阶段后非空；单份）。
  FileDeliveryResult? wordDeliveryResult;

  /// 整单失败原因（phase == failed 时非空；面向用户的明确说明）。
  String? error;

  /// 生成进度：当前第几题（按题推进）。
  int progressDone = 0;

  /// 生成进度：共几题。
  int progressTotal = 0;

  /// 生成进度文案（“正在准备题目…” / “正在处理公式…” /
  /// “正在生成 PDF…” / “正在保存文件…”）。
  String progressLabel = '';

  /// 本次取消令牌（每次 start() 新建；取消即停）。
  ExportCancellationToken? _token;

  /// 当前平台是否 Android（Android 只出「分享」，无内置打开通道，
  /// 见 pdf_delivery.dart 文件头；测试可用 platformOverride 覆盖）。
  bool get isAndroid =>
      platformOverride == PdfDeliveryPlatform.android ||
      (platformOverride == null && Platform.isAndroid);

  /// 是否支持直接打开文件 / 文件夹（桌面端；Android 不支持，
  /// 只出「分享」）。
  bool get supportsOpen => !isAndroid;

  /// 盘点（确认步进入时调；失败 → phase failed + [error]）。
  Future<void> prepare({
    required List<String> ids,
    required List<ExcludedQuestion> excluded,
    required int circledCount,
  }) async {
    _setPhase(ExportFlowPhase.preparing);
    error = null;
    inventory = null;
    try {
      inventory = await computeInventory(
        ids: ids,
        excluded: excluded,
        circledCount: circledCount,
      );
      // 盘点本身不推进阶段：确认内容由确认步展示，仍停在 preparing
      // 语义上等价于“待确认”；确认步以 inventory 非空判定加载完成。
      // 阶段保持 preparing 直到 start() 或新的 prepare()。
      notifyListeners();
    } on ExportCancelledException {
      _setPhase(ExportFlowPhase.cancelled);
    } catch (e) {
      error = _userMessage(e);
      _setPhase(ExportFlowPhase.failed);
    }
  }

  /// 开始生成 + 交付（确认步点「生成」后调）。
  ///
  /// [fileNameFor] 为用户确认后的文件名（PDF：含 .pdf；答案版由确认步
  /// 按练习版文件名派生 `_答案` 后缀，见 export_filename.dart；
  /// Word：单份文件，取练习版文件名，扩展名 .docx）。
  /// [format] 决定走 PDF 两版流程还是 Word 单份流程（十六批 C，
  /// D-190/D-194；默认 PDF，现有调用方不受影响）。
  /// 确认前断言 selected.length <= 50（M1-DESIGN §2 第 2 点）：
  /// 超限则阻断生成并报错，不生成文件。
  Future<void> start({
    required List<String> ids,
    required List<ExcludedQuestion> excluded,
    required String filterText,
    required String sortText,
    required ExportVersionSelection versions,
    required int circledCount,
    required String Function(ExportVersion version) fileNameFor,
    String subjectName = '多学科',
    String? folderName,
    bool excludeLowDpi = false,
    ExportFormat format = ExportFormat.pdf,
  }) async {
    if (ids.length > kExportMaxQuestions) {
      error = '单次最多导出 50 道题';
      _setPhase(ExportFlowPhase.failed);
      return;
    }
    if (!versions.hasAny) {
      error = '至少选择一个版本';
      _setPhase(ExportFlowPhase.failed);
      return;
    }
    final token = _token = ExportCancellationToken();
    progressDone = 0;
    progressTotal = ids.length;
    progressLabel = '正在准备题目…';
    versionsResult = null;
    wordResult = null;
    deliveryResults = null;
    wordDeliveryResult = null;
    error = null;
    _setPhase(ExportFlowPhase.generating);
    if (format == ExportFormat.word) {
      await _startWord(
        ids: ids,
        excluded: excluded,
        filterText: filterText,
        sortText: sortText,
        versions: versions,
        circledCount: circledCount,
        fileNameFor: fileNameFor,
        subjectName: subjectName,
        folderName: folderName,
        excludeLowDpi: excludeLowDpi,
        token: token,
      );
      return;
    }
    try {
      final result = await generateVersions(
        ids: ids,
        excluded: excluded,
        filterText: filterText,
        sortText: sortText,
        versions: versions,
        circledCount: circledCount,
        token: token,
        onProgress: (done, total, label) {
          progressDone = done;
          progressTotal = total;
          progressLabel = label;
          notifyListeners();
        },
        subjectName: subjectName,
        folderName: folderName,
        excludeLowDpi: excludeLowDpi,
      );
      versionsResult = result;
      if (!result.anySucceeded) {
        error =
            result.practice?.error ??
            result.answer?.error ??
            '生成失败，请重试。';
        _setPhase(ExportFlowPhase.failed);
        return;
      }
      // 交付：逐份交付已生成的版本（P1-5：每份独立记状态）。
      _setPhase(ExportFlowPhase.delivering);
      progressLabel = '正在保存文件…';
      notifyListeners();
      final requests = <VersionDeliveryRequest>[];
      for (final version in versions.selected) {
        final outcome = version == ExportVersion.practice
            ? result.practice
            : result.answer;
        final generated = outcome?.result;
        if (generated == null) continue;
        requests.add(
          VersionDeliveryRequest(
            pdfBytes: generated.pdfBytes,
            fileName: fileNameFor(version),
            version: version,
            expectedPages: generated.totalPages,
          ),
        );
      }
      deliveryResults = await deliverAll(requests: requests);
      _setPhase(ExportFlowPhase.done);
    } on ExportCancelledException {
      // 取消即停：服务侧已清理快照临时目录，不留半截 PDF。
      _setPhase(ExportFlowPhase.cancelled);
    } catch (e) {
      error = _userMessage(e);
      _setPhase(ExportFlowPhase.failed);
    }
  }

  /// Word 单份流程：生成一份 .docx（练习版与答案版在同一文件内）
  /// → 单份交付。生成/交付回调未接入时整单失败（不静默回落 PDF）。
  Future<void> _startWord({
    required List<String> ids,
    required List<ExcludedQuestion> excluded,
    required String filterText,
    required String sortText,
    required ExportVersionSelection versions,
    required int circledCount,
    required String Function(ExportVersion version) fileNameFor,
    required String subjectName,
    required String? folderName,
    required bool excludeLowDpi,
    required ExportCancellationToken token,
  }) async {
    final generate = generateWord;
    final deliver = deliverWord;
    if (generate == null || deliver == null) {
      error = 'Word 导出未接入，请稍后再试。';
      _setPhase(ExportFlowPhase.failed);
      return;
    }
    try {
      final result = await generate(
        ids: ids,
        excluded: excluded,
        filterText: filterText,
        sortText: sortText,
        versions: versions,
        circledCount: circledCount,
        token: token,
        onProgress: (done, total, label) {
          progressDone = done;
          progressTotal = total;
          progressLabel = label;
          notifyListeners();
        },
        subjectName: subjectName,
        folderName: folderName,
        excludeLowDpi: excludeLowDpi,
      );
      wordResult = result;
      // 交付：单份交付（无部分成功语义；一份文件要么交付要么失败）。
      _setPhase(ExportFlowPhase.delivering);
      progressLabel = '正在保存文件…';
      notifyListeners();
      wordDeliveryResult = await deliver(
        docxBytes: result.docxBytes,
        fileName: fileNameFor(ExportVersion.practice),
        expectedImageCount: result.imageCount,
      );
      _setPhase(ExportFlowPhase.done);
    } on ExportCancelledException {
      // 取消即停：服务侧已清理快照临时目录，不留半截 docx。
      _setPhase(ExportFlowPhase.cancelled);
    } catch (e) {
      error = _userMessage(e);
      _setPhase(ExportFlowPhase.failed);
    }
  }

  /// 请求取消（进度界面「取消」按钮；取消后服务侧停在下一个检查点，
  /// 清理临时文件，不留半截 PDF，不留僵尸 Isolate）。
  void cancel() => _token?.cancel();

  /// 完成界面展示行（生成结果 + 交付结果按版本拼行；生成失败的版本
  /// 只有生成错误行；部分成功时逐份列出成功/失败，不得伪装）。
  ///
  /// Word 格式时只有一行（标签 'Word'，不带页数，题数为已印题数，
  /// 文件大小为实际字节数）。
  List<ExportCompletionRow> get completionRows {
    final word = wordResult;
    if (word != null) {
      final delivered = wordDeliveryResult;
      return [
        ExportCompletionRow(
          version: ExportVersion.practice,
          fileName: delivered?.fileName ?? '',
          pageCount: null,
          questionCount:
              word.report.completeCount + word.report.partialCount,
          deliveredPath: delivered?.isDelivered == true
              ? delivered!.filePath
              : null,
          deliveryError: delivered?.status == FileDeliveryStatus.failed
              ? delivered!.error
              : delivered?.status == FileDeliveryStatus.cancelled
              ? '已取消保存'
              : null,
          labelOverride: 'Word',
          isWordCombined: true,
          fileSizeBytes: word.docxBytes.length,
        ),
      ];
    }
    final result = versionsResult;
    if (result == null) return const [];
    final rows = <ExportCompletionRow>[];
    for (final version in <ExportVersion>[
      ExportVersion.practice,
      ExportVersion.answer,
    ]) {
      final outcome = version == ExportVersion.practice
          ? result.practice
          : result.answer;
      if (outcome == null) continue;
      final generated = outcome.result;
      final delivered = deliveryResults
          ?.where((r) => r.version == version)
          .firstOrNull;
      if (generated == null) {
        rows.add(
          ExportCompletionRow(
            version: version,
            fileName: '',
            generationError: outcome.error ?? '生成失败，请重试。',
          ),
        );
        continue;
      }
      rows.add(
        ExportCompletionRow(
          version: version,
          fileName: delivered?.fileName ?? '',
          pageCount: delivered?.pageCount ?? generated.totalPages,
          questionCount: generated.report.snapshotCount,
          deliveredPath: delivered?.isDelivered == true
              ? delivered!.filePath
              : null,
          deliveryError: delivered?.status == FileDeliveryStatus.failed
              ? delivered!.error
              : delivered?.status == FileDeliveryStatus.cancelled
              ? '已取消保存'
              : null,
        ),
      );
    }
    return rows;
  }

  /// 完整性报告摘要行（完成界面展示；按路线两张表，见 M1-DESIGN §12）。
  ///
  /// 返回空列表表示无报告可展示（如生成失败）。Word 格式时在末尾
  /// 追加两行：文件实际大小 + 字体未嵌入提示（D-193；不编造页数）。
  List<String> get reportSummaryLines {
    final word = wordResult;
    final report = word?.report ?? versionsResult?.report;
    if (report == null) return const [];
    final lines = <String>[];
    final routeLabel = report.route == ExportRoute.c
        ? 'OCR 重排路线'
        : '图片增强路线';
    lines.add('本次路线：$routeLabel');
    if (report.route == ExportRoute.c) {
      final formulaOriginal = report.entries
          .where((e) => e.warnings.contains('公式为原图'))
          .length;
      lines.add(
        '可印 ${report.completeCount + report.partialCount} / '
        '${report.selectedCount} 道'
        '、跳过 ${report.skippedCount} / ${report.selectedCount} 道'
        '、公式为原图 $formulaOriginal 道',
      );
    } else {
      final fallback = report.entries
          .where((e) => e.warnings.contains('增强失败，已用原图'))
          .length;
      final lowDpi = inventory?.lowDpi.length ?? 0;
      lines.add(
        '增强后印出 ${report.completeCount + report.partialCount} / '
        '${report.selectedCount} 道'
        '、回退原图 $fallback 道'
        '、低于清晰度阈值 $lowDpi 道',
      );
    }
    if (report.answersRecorded != null) {
      lines.add(
        '答案已录入 ${report.answersRecorded} / ${report.answersTotal} 道'
        '、解析已录入 ${report.explanationsRecorded ?? 0} / '
        '${report.explanationsTotal} 道',
      );
    }
    if (word != null) {
      lines.add('文件大小：${_formatBytes(word.docxBytes.length)}');
      lines.add('字体未嵌入：在未安装 Noto Sans SC 的电脑上打开时，'
          'Word 会以替用字体显示。');
    }
    return lines;
  }

  /// 警告清单明细（有跳过 / 缺失 / 降级题时可展开看；每项含题名与原因）。
  List<String> get warningDetails {
    final report = wordResult?.report ?? versionsResult?.report;
    if (report == null) return const [];
    final lines = <String>[];
    for (final entry in report.entries) {
      if (entry.status == IntegrityStatus.skipped) {
        lines.add('${entry.title}：跳过（${entry.skipReason ?? '未印出'}）');
      } else if (entry.status == IntegrityStatus.broken) {
        lines.add('${entry.title}：主图缺失，已印占位说明');
      } else if (entry.warnings.isNotEmpty) {
        lines.add('${entry.title}：${entry.warnings.join('；')}');
      }
    }
    return lines;
  }

  /// 打开文件（桌面端；Android 不出此按钮，见 [supportsOpen]）。
  Future<bool> openDeliveredFile(String path) async {
    final fn = openFile;
    if (fn == null) return false;
    return fn(path);
  }

  /// 打开所在文件夹（桌面端）。
  Future<bool> openDeliveredFolder(String path) async {
    final fn = openFolder;
    if (fn == null) return false;
    return fn(path);
  }

  /// 系统分享（Android「分享」；桌面端同样可用）。
  Future<ShareResult?> shareDeliveredFile(String path) async {
    final fn = shareFile;
    if (fn == null) return null;
    return fn(path);
  }

  void _setPhase(ExportFlowPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  /// 字节数转人类可读大小（Word 完成行展示用实际大小）。
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _userMessage(Object e) {
    if (e is ExportNoPrintableException) return e.message;
    if (e is ExportGuardRejectException) return e.message;
    if (e is RouteResolutionException) return e.message;
    if (e is ArgumentError) return e.message ?? '参数错误';
    if (e is StateError) return e.message;
    return '生成失败，请重试。';
  }
}
