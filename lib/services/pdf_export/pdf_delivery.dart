// 十五批 M2-3：平台交付（PLAN-15-REV3 §5 M2-3；M3 调用的交付 API）。
//
// 两端同一套 PDF 生成逻辑，平台差异只在落盘与打开/分享方式：
// - Windows：`FilePicker.platform.saveFile` 另存为对话框（沿用
//   QuestionExportService 同款：桌面端只返回路径，自己写文件）；
//   对话框返回的路径即用户确认的位置（含覆盖确认——对话框的覆盖
//   确认为准，见 M2-2；file_picker 8.3.7 的 Windows 覆盖确认行为
//   列入 M4 真机清单验证）；完成后提供「打开文件 / 打开所在文件夹」
//   （桌面端经系统启动器打开）；取消返回 null 即整单取消，不留文件。
// - Android：保存到公共下载目录（`path_provider`
//   `getDownloadsDirectory()`；目录须明确、可找到，不得写到用户找
//   不到的私有目录；返回 null 或不可用时整单失败并明确报错，绝不
//   静默改写私有目录）；完成后提供「打开 PDF / 分享」——分享走系统
//   分享（share_plus 12.0.2，已验证可解析）；直接打开走 open_filex
//   （二十批 P7，十五批 #31：独立「打开 PDF」按钮，
//   `PdfDeliveryService.openPdf` 在 Android/iOS 上改走 open_filex，
//   桌面端仍走系统启动器；本机 Linux 测不了真机打开行为，
//   真机验证见 M4 真机清单）。
// - iOS：打开同样走 open_filex（与 Android 同一通道）；落盘交付
//   仍只支持 Windows 与 Android（见 [PdfDeliveryService.deliver]）。
// - 公共 Downloads 的实际交付以 S1 真机验证结论为准（P1-3）：S1.6
//   真机验证未做，Linux 侧不得把通过当作公共 Downloads 交付已证实，
//   明确记入 M4 真机清单；若实际得到只是应用私有目录，不得当作
//   公共 Downloads 交付。
//
// 双文件部分成功语义（P1-5）：每份 PDF 是独立的原子交付单元；
// [deliverAll] 逐份交付、逐份记状态，一份失败不影响已交付的另一份，
// 也不得把部分成功伪装成全部成功（调用方按返回列表逐份展示）。
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'atomic_file_writer.dart';
import 'export_versions.dart';

/// 一份文件的交付状态（M3 完成界面逐份展示用）。
enum FileDeliveryStatus {
  /// 已完整验证并发布。
  delivered,

  /// 用户取消（另存为对话框取消；不留文件，不是失败）。
  cancelled,

  /// 交付失败（原因见 [FileDeliveryResult.error]；无半成品）。
  failed,
}

/// 一份文件的交付结果（M3 完成界面展示的最小数据）。
class FileDeliveryResult {
  const FileDeliveryResult({
    required this.status,
    required this.version,
    required this.fileName,
    this.filePath,
    this.error,
    this.pageCount,
  });

  /// 交付状态。
  final FileDeliveryStatus status;

  /// 版本（练习版 / 答案版）。
  final ExportVersion version;

  /// 文件名（落盘后的实际文件名；冲突顺延时与请求名不同）。
  final String fileName;

  /// 落盘后的完整路径（delivered 时非空）。
  final String? filePath;

  /// 失败原因（failed 时非空；面向用户的明确说明）。
  final String? error;

  /// 页数（delivered 时为验证通过的页数）。
  final int? pageCount;

  /// 是否已交付。
  bool get isDelivered => status == FileDeliveryStatus.delivered;
}

/// 一份文件的交付请求（[PdfDeliveryService.deliverAll] 的输入）。
class VersionDeliveryRequest {
  const VersionDeliveryRequest({
    required this.pdfBytes,
    required this.fileName,
    required this.version,
    required this.expectedPages,
  });

  /// 已验证的 PDF 字节（生成服务输出）。
  final Uint8List pdfBytes;

  /// 期望文件名（由 [buildExportFileName] 生成）。
  final String fileName;

  /// 版本。
  final ExportVersion version;

  /// 预期页数（原子写入验证用）。
  final int expectedPages;
}

/// 系统分享结果。
enum ShareOutcome {
  /// 用户选了分享动作（不保证对方真的收到，见 share_plus 文档）。
  shared,

  /// 用户关闭了分享面板。
  dismissed,

  /// 分享结果不可用（平台未返回结果，如 Linux）。
  unavailable,

  /// 分享失败（原因见 [ShareResult.error]）。
  failed,
}

/// 系统分享结果（M3 展示用）。
class ShareResult {
  const ShareResult({required this.outcome, this.error});

  /// 分享结果。
  final ShareOutcome outcome;

  /// 失败原因（failed 时非空）。
  final String? error;
}

/// 打开 PDF 的详细结果（二十批 P7：失败必须带明确原因，不静默吞掉；
/// [PdfDeliveryService.openPdf] 只返回 bool，本类供需要报错文案的
/// 调用方用）。
class OpenPdfResult {
  const OpenPdfResult({required this.success, this.error});

  /// 是否已成功调起打开。
  final bool success;

  /// 失败原因（success 为 false 时非空；面向用户的明确说明）。
  final String? error;
}

/// 系统打开结果（open_filex 的 [OpenResult] 的测试替身类型：
/// 生产走 open_filex，测试注入返回 [OpenResult] 的假函数）。
typedef OpenWithFilexFn = Future<OpenResult> Function(String path);

/// 另存为对话框（Windows；取消返回 null）。
typedef SaveFilePicker =
    Future<String?> Function({
      required String dialogTitle,
      required String fileName,
    });

/// 平台分发（仅测试用：覆盖平台判定，Linux 测试机上模拟
/// Windows/Android 流程；生产传 null，按真实平台分发）。
enum PdfDeliveryPlatform { windows, android, other }

/// 平台交付服务：输入 PDF 字节 + 文件名 + 版本信息，输出每份文件的
/// 交付结果与状态，供 M3 完成界面展示。
///
/// 外部边界全部可注入（测试用假实现，不弹系统对话框、不碰真实
/// 下载目录、不调真实分享/启动器）；默认实现即生产行为。
class PdfDeliveryService {
  PdfDeliveryService({
    SaveFilePicker? pickSavePath,
    Future<Directory?> Function()? downloadsDirectory,
    Future<ShareResultStatus> Function(String path, String subject)?
    shareFile,
    Future<bool> Function(String path)? openFile,
    Future<bool> Function(String path)? openFolder,
    OpenWithFilexFn? openWithFilex,
    this._platformOverride,
  }) : _pickSavePath = pickSavePath ?? _defaultPickSavePath,
       _downloadsDirectory =
           downloadsDirectory ?? getDownloadsDirectory,
       _shareFile = shareFile ?? _defaultShareFile,
       _openFile = openFile ?? _defaultOpenFile,
       _openFolder = openFolder ?? _defaultOpenFolder,
       _openWithFilex = openWithFilex ?? _defaultOpenWithFilex;

  final SaveFilePicker _pickSavePath;
  final Future<Directory?> Function() _downloadsDirectory;
  final Future<ShareResultStatus> Function(String path, String subject)
  _shareFile;
  final Future<bool> Function(String path) _openFile;
  final Future<bool> Function(String path) _openFolder;
  final OpenWithFilexFn _openWithFilex;
  final PdfDeliveryPlatform? _platformOverride;

  /// 当前分发平台（测试覆盖优先，否则按真实平台）。
  PdfDeliveryPlatform get _platform =>
      _platformOverride ??
      (Platform.isWindows
          ? PdfDeliveryPlatform.windows
          : Platform.isAndroid
          ? PdfDeliveryPlatform.android
          : PdfDeliveryPlatform.other);

  /// 当前平台是否支持直接打开文件（桌面端：Windows/Linux/macOS；
  /// Android/iOS 走 open_filex，见 [openPdfWithResult]，不在此
  /// getter 内——它只描述桌面端系统启动器路径）。
  static bool get supportsOpenFile =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// 当前平台的打开通道是否走 open_filex（Android／iOS；二十批 P7）。
  ///
  /// 测试用 [_platformOverride] 覆盖时按覆盖值判定；iOS 在
  /// [_platform] 里落到 other，用真实 [Platform.isIOS] 补判定。
  bool get _opensWithFilex =>
      _platform == PdfDeliveryPlatform.android || Platform.isIOS;

  /// 按平台分发交付（一份文件）：Windows 走另存为对话框，
  /// Android 走公共下载目录，其它平台返回失败（不静默改写别处）。
  ///
  /// 十六批 C（D-195）：Word 复用本方法，只换三处——[validator]
  ///（默认 `defaultPdfFileValidator`，PDF 页数校验）、[dialogTitle]
  ///（默认 '保存 PDF'）、[includePageCount]（默认 true；Word 传
  /// false，结果不带页数）。三者都不传时行为与原来完全一致。
  Future<FileDeliveryResult> deliver({
    required Uint8List pdfBytes,
    required String fileName,
    required ExportVersion version,
    required int expectedPages,
    PdfFileValidator? validator,
    String? dialogTitle,
    bool includePageCount = true,
  }) {
    if (_platform == PdfDeliveryPlatform.windows) {
      return deliverWindows(
        pdfBytes: pdfBytes,
        fileName: fileName,
        version: version,
        expectedPages: expectedPages,
        validator: validator,
        dialogTitle: dialogTitle ?? '保存 PDF',
        includePageCount: includePageCount,
      );
    }
    if (_platform == PdfDeliveryPlatform.android) {
      return deliverAndroid(
        pdfBytes: pdfBytes,
        fileName: fileName,
        version: version,
        expectedPages: expectedPages,
        validator: validator,
        includePageCount: includePageCount,
      );
    }
    return Future.value(
      FileDeliveryResult(
        status: FileDeliveryStatus.failed,
        version: version,
        fileName: fileName,
        error: '当前平台暂不支持导出落盘（仅支持 Windows 与 Android）。',
      ),
    );
  }

  /// Windows：另存为对话框选位置 → 原子写入。
  ///
  /// 对话框取消返回 null → 整单取消，不留文件。对话框返回的路径
  /// 即用户确认的位置（含覆盖确认），以对话框的覆盖确认为准
  /// （`overwrite: true`；覆盖前须已完成临时文件验证，见原子写入器）。
  Future<FileDeliveryResult> deliverWindows({
    required Uint8List pdfBytes,
    required String fileName,
    required ExportVersion version,
    required int expectedPages,
    PdfFileValidator? validator,
    String dialogTitle = '保存 PDF',
    bool includePageCount = true,
  }) async {
    final picked = await _pickSavePath(
      dialogTitle: dialogTitle,
      fileName: fileName,
    );
    if (picked == null) {
      return FileDeliveryResult(
        status: FileDeliveryStatus.cancelled,
        version: version,
        fileName: fileName,
      );
    }
    return deliverToPath(
      pdfBytes: pdfBytes,
      targetPath: picked,
      version: version,
      expectedPages: expectedPages,
      overwrite: true,
      validator: validator,
      includePageCount: includePageCount,
    );
  }

  /// Android：保存到公共下载目录 → 原子写入。
  ///
  /// 下载目录取不到或不可用 → 整单失败并明确报错，绝不静默改写
  /// 应用私有目录。目标已存在时顺延命名（无对话框可确认覆盖）。
  Future<FileDeliveryResult> deliverAndroid({
    required Uint8List pdfBytes,
    required String fileName,
    required ExportVersion version,
    required int expectedPages,
    PdfFileValidator? validator,
    bool includePageCount = true,
  }) async {
    final downloads = await _downloadsDirectory();
    if (downloads == null) {
      return FileDeliveryResult(
        status: FileDeliveryStatus.failed,
        version: version,
        fileName: fileName,
        error: '无法取得系统下载目录，请检查存储权限后重试。',
      );
    }
    final targetPath =
        '${downloads.path}${Platform.pathSeparator}$fileName';
    return deliverToPath(
      pdfBytes: pdfBytes,
      targetPath: targetPath,
      version: version,
      expectedPages: expectedPages,
      overwrite: false,
      validator: validator,
      includePageCount: includePageCount,
    );
  }

  /// 写到明确指定的路径（平台无关的核心：原子写入 + 验证）。
  ///
  /// [overwrite] 为 true 仅当调用方已取得用户覆盖确认（如 Windows
  /// 另存为对话框）；默认 false → 目标已存在时顺延命名。
  /// [validator] 为 null 时用默认 PDF 校验（页数与预期一致）；
  /// [includePageCount] 为 false 时结果不带页数（Word：页数生成时未知）。
  /// 本方法不抛错：失败以 [FileDeliveryResult] 返回（M3 直接展示）。
  Future<FileDeliveryResult> deliverToPath({
    required Uint8List pdfBytes,
    required String targetPath,
    required ExportVersion version,
    required int expectedPages,
    bool overwrite = false,
    PdfFileValidator? validator,
    bool includePageCount = true,
  }) async {
    try {
      final file = await writePdfAtomically(
        target: File(targetPath),
        bytes: pdfBytes,
        expectedPages: expectedPages,
        overwrite: overwrite,
        validate: validator,
      );
      return FileDeliveryResult(
        status: FileDeliveryStatus.delivered,
        version: version,
        fileName: file.uri.pathSegments.last,
        filePath: file.path,
        pageCount: includePageCount ? expectedPages : null,
      );
    } on AtomicWriteException catch (e) {
      return FileDeliveryResult(
        status: FileDeliveryStatus.failed,
        version: version,
        fileName: targetPath.split(Platform.pathSeparator).last,
        error: e.message,
      );
    } catch (e) {
      return FileDeliveryResult(
        status: FileDeliveryStatus.failed,
        version: version,
        fileName: targetPath.split(Platform.pathSeparator).last,
        error: '交付失败：$e',
      );
    }
  }

  /// 逐份交付多份文件（双文件部分成功语义 P1-5）：每份独立记状态，
  /// 一份失败不影响已交付的另一份；返回列表按请求顺序，供完成界面
  /// 逐份展示成功/失败状态与原因。
  Future<List<FileDeliveryResult>> deliverAll({
    required List<VersionDeliveryRequest> requests,
  }) async {
    final results = <FileDeliveryResult>[];
    for (final request in requests) {
      results.add(
        await deliver(
          pdfBytes: request.pdfBytes,
          fileName: request.fileName,
          version: request.version,
          expectedPages: request.expectedPages,
        ),
      );
    }
    return results;
  }

  /// 系统分享（Android「分享」；Windows/Linux 同样可用分享面板）。
  ///
  /// 文件不存在 → failed。用户关闭分享面板 → dismissed（不是失败）。
  Future<ShareResult> sharePdf(String path, {String? subject}) async {
    if (!File(path).existsSync()) {
      return const ShareResult(
        outcome: ShareOutcome.failed,
        error: '要分享的文件不存在。',
      );
    }
    try {
      final status = await _shareFile(path, subject ?? '错题本导出');
      return switch (status) {
        ShareResultStatus.success =>
          const ShareResult(outcome: ShareOutcome.shared),
        ShareResultStatus.dismissed =>
          const ShareResult(outcome: ShareOutcome.dismissed),
        ShareResultStatus.unavailable =>
          const ShareResult(outcome: ShareOutcome.unavailable),
      };
    } catch (e) {
      return ShareResult(outcome: ShareOutcome.failed, error: '分享失败：$e');
    }
  }

  /// 打开 PDF（桌面端：系统启动器按默认阅读器打开；Android/iOS：
  /// open_filex 调起系统查看器，二十批 P7）。
  ///
  /// 文件不存在返回 false。失败原因见 [openPdfWithResult]，本方法
  /// 只保留 bool 兼容旧调用方（完成界面失败提示用详细结果）。
  Future<bool> openPdf(String path) async =>
      (await openPdfWithResult(path)).success;

  /// 打开 PDF（带明确失败原因版）：文件不存在、没有可打开 PDF 的
  /// 应用、无权限、通道抛错都以 [OpenPdfResult.error] 返回，不静默
  /// 吞掉；成功时 error 为 null。
  Future<OpenPdfResult> openPdfWithResult(String path) async {
    if (!File(path).existsSync()) {
      return const OpenPdfResult(
        success: false,
        error: '要打开的文件不存在。',
      );
    }
    if (_opensWithFilex) {
      try {
        final result = await _openWithFilex(path);
        return switch (result.type) {
          ResultType.done => const OpenPdfResult(success: true),
          ResultType.fileNotFound => const OpenPdfResult(
            success: false,
            error: '要打开的文件不存在。',
          ),
          ResultType.noAppToOpen => const OpenPdfResult(
            success: false,
            error: '没有可打开 PDF 的应用，请先安装 PDF 阅读器。',
          ),
          ResultType.permissionDenied => const OpenPdfResult(
            success: false,
            error: '没有打开该文件的权限，请检查存储权限后重试。',
          ),
          ResultType.error => OpenPdfResult(
            success: false,
            error: result.message.isEmpty
                ? '打开 PDF 失败，请重试。'
                : '打开 PDF 失败：${result.message}',
          ),
        };
      } catch (e) {
        return OpenPdfResult(success: false, error: '打开 PDF 失败：$e');
      }
    }
    try {
      final ok = await _openFile(path);
      return ok
          ? const OpenPdfResult(success: true)
          : const OpenPdfResult(
              success: false,
              error: '打开文件失败，请检查默认 PDF 阅读器。',
            );
    } catch (e) {
      return OpenPdfResult(success: false, error: '打开文件失败：$e');
    }
  }

  /// 打开所在文件夹（桌面端；Android/iOS 返回 false）。
  Future<bool> openContainingFolder(String path) async {
    if (!File(path).existsSync()) return false;
    return _openFolder(path);
  }

  static Future<String?> _defaultPickSavePath({
    required String dialogTitle,
    required String fileName,
  }) => FilePicker.platform.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
  );

  static Future<ShareResultStatus> _defaultShareFile(
    String path,
    String subject,
  ) async {
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path)],
        subject: subject,
      ),
    );
    return result.status;
  }

  static Future<OpenResult> _defaultOpenWithFilex(String path) =>
      OpenFilex.open(path);

  static Future<bool> _defaultOpenFile(String path) async {
    if (Platform.isWindows) return _runLauncher('explorer', [path]);
    if (Platform.isLinux) return _runLauncher('xdg-open', [path]);
    if (Platform.isMacOS) return _runLauncher('open', [path]);
    return false;
  }

  static Future<bool> _defaultOpenFolder(String path) async {
    final dir = File(path).parent.path;
    if (Platform.isWindows) return _runLauncher('explorer', [dir]);
    if (Platform.isLinux) return _runLauncher('xdg-open', [dir]);
    if (Platform.isMacOS) return _runLauncher('open', [dir]);
    return false;
  }

  static Future<bool> _runLauncher(
    String executable,
    List<String> args,
  ) async {
    try {
      final result = await Process.run(executable, args);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
