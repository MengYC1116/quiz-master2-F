// 十五批 M1-E：编排服务 PdfExportService（M1-DESIGN.md §1/§7）。
//
// 流程：路由判定 → 盘点 M1-0 → 快照 M1-1 → 生成（后台 Isolate 内，
// `pdf` 纯 Dart）→ 完整性报告。输出“已验证的 PDF 字节 + 报告”，
// 不含文件发布（发布属 M2 的 PdfDeliveryService；M1 内部测试写临时文件即可）。
//
// 十五批 M2-1（两版生成）：[generate] / [generateFromSnapshot] 增加
// [ExportVersion] 参数（默认练习版）；[generateVersions] 先冻结一次
// 快照、再按选中版本逐版生成（同一快照、同一路线、同一题号序列，
// 不得重新独立查询题目）。双文件部分成功语义（P1-5）：每版独立记
// 成功/失败，一版失败不删已得到的另一版，也不伪装成全部成功；
// 取消（[ExportCancelledException]）是整单取消，不是部分成功，
// 直接原样抛出。答案版的答案区在生成 Isolate 内两阶段构建：先建
// 题目文档取题号、答案区单独排版计数页数，再按已知总页数重建题目
// 文档并接上答案区 MultiPage（页码全局连续），保存后数页校验，
// 对不上即整单失败、不发布（见 answer_section.dart 与
// pdf_page_counter.dart）。
//
// - 服务入口复核快照题数 ≤ 50（§2 第 4 点，第二道防线；快照工厂
//   已校验，此处再复核一次）。
// - 路由在快照创建时冻结：路由只读一次，生成全程用快照的 route，
//   中途 key 变化不切换。
// - 生成在后台 Isolate：构建（C/A 内容构建器）与 `save()` 都在
//   Isolate 内跑；`save()` 经 M1-A 的 `savePdf` await（C-7，唯一
//   保存入口）。主 Isolate 只做路由/盘点/快照/公式栅格化（Widget，
//   只能在主 Isolate）/分页规划（TextPainter， main Isolate）。
// - 取消检查点（S1 §7 模型）：每题生成前 `await Future.delayed(
//   Duration.zero)` 让出执行权再检查标志（见 [ExportCancellationToken.checkpoint]）；
//   图片读取/解码、分页、每题生成各阶段均在检查点之后；取消后释放
//   资源、清理临时目录（快照 dispose 删整个临时目录），不留半截 PDF；
//   强制终止 Isolate 时由编排层清理整个临时目录（本服务在取消路径
//   上 kill Isolate 后 dispose 快照）。
// - 两遍布局：先对整份快照做完整分页规划（页数、每页题目、断点位置），
//   再按已知总页数渲染“第 x / y 页”；C 路线两遍布局不导致公式重复渲染
//   （公式位图只在快照后栅格化一次，两遍只复用文件引用与尺寸）。
// - 分页结果确定性：同一快照在同一平台两次生成，分页结果一致
//   （规划是纯函数；Isolate 内构建只读规划，不重排）。
// - 逐题处理，不一次性把全部文本/公式位图/图块常驻内存；图片按题
//   逐个读取、嵌入、释放（构建器内逐题读，见 M1-C/M1-D）。
// - LaTeX 源码绝不外露：本文件只见公式标识与文件引用，报错/日志
//   只含题号与原因，不含公式内容（C-11）。
//
// 快照归属：[generate] 内部建快照，结束（成功/失败/取消）后一律
// dispose 快照（删整个临时目录）；[generateFromSnapshot] 不拥有快照，
// 调用方负责 dispose（同一快照两次生成时，两次调用之间不得 dispose）。
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf/widgets.dart' as pw;

import '../../modules/ocr/formula_crop.dart';
import '../../modules/ocr/question_content.dart';
import '../../services/ocr_key_store.dart';
import 'a_content_builder.dart';
import 'answer_section.dart';
import 'c_content_builder.dart';
import 'content_guard.dart';
import 'export_integrity.dart';
import 'export_inventory.dart';
import 'export_question_record.dart';
import 'export_route.dart';
import 'export_snapshot.dart';
import 'export_versions.dart';
import 'formula_rasterizer.dart';
import 'image_enhancer.dart';
import 'pdf_document_builder.dart';
import 'pdf_font.dart';
import 'pdf_page_counter.dart';
import 'slice_snapshot.dart';
import 'slice_write_guard.dart';
import 'snapshot_exceptions.dart';
import 'text_pagination.dart';

/// 生成 Isolate 看门狗超时（D-183：P0-1 运行时兜底）。
///
/// 主 Isolate 等生成 Isolate 回包的最长等待：超时则 kill 子 Isolate
/// 并明确报错“生成超时，已中止，未产生文件”。50 道上限下正常生成
/// 远低于此时长；超时只可能发生在规划期上限漏网时（Release 下
/// MultiPage 无限翻页）。看门狗不能替代规划期上限：死循环在子
/// Isolate 内快速分配页面，超时前可能先 OOM；两者缺一不可。
/// 注意：超时前未产生任何文件（落盘在回包之后才做），故“未产生文件”
/// 为真，不是安慰文案。
const Duration kPdfGenerationWatchdogTimeout = Duration(seconds: 60);

/// 导出被取消（用户取消或调用方取消；不是失败，不留半截 PDF）。
class ExportCancelledException implements Exception {
  const ExportCancelledException();

  @override
  String toString() => 'ExportCancelledException: 导出已取消';
}

/// 本次没有可导出题目（盘点可印数为 0，或快照后最终可印数变 0，或
/// 生成准备后可印题为空；不建快照/不生成 PDF）。
class ExportNoPrintableException implements Exception {
  ExportNoPrintableException(this.message);

  /// 面向用户的明确说明（不含公式内容）。
  final String message;

  @override
  String toString() => 'ExportNoPrintableException: $message';
}

/// 内容 guard 硬拒绝（盘点估算或快照后实际值超 150 Mpx；不生成 PDF）。
class ExportGuardRejectException implements Exception {
  ExportGuardRejectException(this.message, this.guard);

  /// 面向用户的明确说明（含指引，不含公式内容）。
  final String message;

  /// 触发拒绝的 guard 评估结果（估算值或实际值，见 [ContentGuardResult.isEstimate]）。
  final ContentGuardResult guard;

  @override
  String toString() => 'ExportGuardRejectException: $message';
}

/// 导出取消令牌（S1 §7 检查点模型）。
///
/// 调用方（M3 进度界面）持有一个令牌，取消时调 [cancel]；服务在每题
/// 生成前调 [checkpoint]（先 `await Future.delayed(Duration.zero)`
/// 让出执行权，再检查标志）。令牌取消后，栅格化器也会被通知
/// （服务在生成开始时挂一次 `whenCancelled → rasterizer.cancel()`），
/// 飞行中的 `toImage()` 允许当前渲染完成再丢弃结果，不再启动后续渲染。
class ExportCancellationToken {
  final _completer = Completer<void>();

  /// 是否已取消。
  bool get isCancelled => _completer.isCompleted;

  /// 取消时完成的 Future（服务内部用，不对外暴露取消原因）。
  Future<void> get whenCancelled => _completer.future;

  /// 请求取消（重复调用无操作）。
  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }

  /// 已取消则抛 [ExportCancelledException]。
  void throwIfCancelled() {
    if (isCancelled) throw const ExportCancelledException();
  }

  /// 取消检查点：先让出执行权，再检查标志（§7 检查点模型）。
  Future<void> checkpoint() async {
    await Future.delayed(Duration.zero);
    throwIfCancelled();
  }
}

/// 一道题的导出页号（题号序列与分页结果，同一快照两次生成须一致）。
class ExportQuestionPage {
  const ExportQuestionPage({
    required this.questionId,
    required this.displayNumber,
    required this.pages,
  });

  /// 题目 ID。
  final String questionId;

  /// 导出内题号（从 1 计；未印出的题不出现在此表里）。
  final int displayNumber;

  /// 所在页号（从 1 计；跨页题含多页）。
  final List<int> pages;
}

/// 编排服务的一次生成结果（已验证的 PDF 字节 + 报告，不含文件发布）。
class PdfExportResult {
  const PdfExportResult({
    required this.pdfBytes,
    required this.report,
    required this.route,
    required this.totalPages,
    required this.questionPages,
    required this.estimatedGuard,
    required this.actualGuard,
    required this.guardDeviation,
    this.variant = ExportVersion.practice,
  });

  /// 已验证的 PDF 字节（`save()` await 完成后的完整字节，以 `%PDF-` 开头）。
  final Uint8List pdfBytes;

  /// 完整性报告（任务内数据，不存库）。
  final IntegrityReport report;

  /// 本次路线（快照冻结值）。
  final ExportRoute route;

  /// 总页数（分页规划值，与页脚分母一致；答案版含答案区页数）。
  final int totalPages;

  /// 每题题号与所在页（按快照顺序；未印出的题不在此表里）。
  final List<ExportQuestionPage> questionPages;

  /// 盘点 guard 估算值（标注“估算值”，D-181）。
  final ContentGuardResult estimatedGuard;

  /// 快照后实际值复核的 guard 结果（非估算值，D-181）。
  final ContentGuardResult actualGuard;

  /// 估算值与实际值的偏差记录（尤其 C 路线，记入验证记录）。
  final GuardDeviation guardDeviation;

  /// 本次版本（练习版 / 答案版；M2-1）。
  final ExportVersion variant;
}

/// 一版的生成结果（M2-1 双文件部分成功语义 P1-5：成功含结果，
// 失败含原因；未选中的版本不在结果里出现）。
class VersionExportOutcome {
  const VersionExportOutcome.success(this.result) : error = null;

  const VersionExportOutcome.failure(this.error) : result = null;

  /// 成功时的生成结果（失败时为 null）。
  final PdfExportResult? result;

  /// 失败原因（成功时为 null；面向用户的明确说明）。
  final String? error;

  /// 是否成功。
  bool get succeeded => result != null;
}

/// 一次双版生成的结果（同一快照、同一路线；两版题号序列相同）。
class TwoVersionExportResult {
  const TwoVersionExportResult({
    required this.practice,
    required this.answer,
    required this.route,
    required this.report,
  });

  /// 练习版结果（未选中时为 null）。
  final VersionExportOutcome? practice;

  /// 答案版结果（未选中时为 null）。
  final VersionExportOutcome? answer;

  /// 本次路线（快照冻结值，两版相同）。
  final ExportRoute route;

  /// 完整性报告（两版共用同一份报告；两版都失败时为快照层初步报告）。
  final IntegrityReport report;

  /// 选中的版本是否全部成功（M3 完成界面据此展示全部/部分成功；
  /// 部分成功不得伪装成全部成功）。
  bool get allSucceeded {
    final outcomes = [
      if (practice != null) practice!,
      if (answer != null) answer!,
    ];
    if (outcomes.isEmpty) return false;
    return outcomes.every((o) => o.succeeded);
  }

  /// 是否至少一版成功。
  bool get anySucceeded {
    final outcomes = [
      if (practice != null) practice!,
      if (answer != null) answer!,
    ];
    return outcomes.any((o) => o.succeeded);
  }
}

/// 编排服务：路由 → 盘点 → 快照 → 生成 → 报告。
class PdfExportService {
  PdfExportService({
    required this.source,
    Future<bool> Function()? hasApiKey,
    Future<Uint8List> Function()? fontBytesLoader,
    this.tempRoot,
    this.rasterizer,
    this.sourceTextFor,
    this.subjectName = '多学科',
    this.excludeLowDpi = false,
    this.excludeBelowDpi = kClarityWarnDpi,
  }) : _hasApiKey = hasApiKey ?? OcrKeyStore().hasApiKey,
       _fontBytesLoader =
           fontBytesLoader ?? PdfExportFont.loadBundledFontBytes;

  /// 数据源（生产用 [DriftExportQuestionSource]，测试用桩）。
  final ExportQuestionSource source;

  /// 读 OCR key 状态（只读有无，不读 key 本身；默认走 [OcrKeyStore]）。
  final Future<bool> Function() _hasApiKey;

  /// 读导出字体字节（默认读打包 asset；传给生成 Isolate 用）。
  final Future<Uint8List> Function() _fontBytesLoader;

  /// 快照临时目录根（仅测试用；默认系统临时目录）。
  final Directory? tempRoot;

  /// 公式栅格化器（调用方已 attach；C 路线有公式时用。null 时公式
  /// 走纯裁剪降级链：裁剪成功 → 原图（PARTIAL），裁剪失败 → 整题跳过）。
  final FormulaRasterizer? rasterizer;

  /// 每题来源行文字（学科 / 文件夹 / 考试名，M3-F：文件夹与考试名
  /// 取冻结记录上的已解析展示名；不传则不印来源行。
  /// M3 传入真实名称；M1 默认不印来源行（不拿 subjectId 等原始 ID 充数）。
  final String Function(ExportQuestionRecord record)? sourceTextFor;

  /// 页眉学科名（多学科时传“多学科”，不得取第一道题的学科作代表）。
  final String subjectName;

  /// M3 面板勾选“排除低于清晰度阈值的题”（默认 false，只警告、不排除）。
  final bool excludeLowDpi;

  /// 清晰度门禁排除阈值（默认 200 DPI）。
  final double excludeBelowDpi;

  /// 生成一次导出（单版；双版用 [generateVersions]）。
  ///
  /// [ids] 为选中的原始题目 ID（filteredAll() 顺序，含排除题，≤ 50；
  /// 跳过题仍占名额，不得跳过后补入第 51 道，C-14）。
  /// [excluded] 为其中被排除的题（用户主动排除 / 清晰度门禁排除）。
  /// [circledCount] 为筛选范围题数（默认 = 本次选中题数）。
  /// [token] 为取消令牌（不传则用永不取消的令牌）。
  /// [variant] 为版本（默认练习版；答案版题目正文照常印，答案与解析
  /// 集中放在全部题目之后）。
  /// [onProgress] 为 M3 进度回调（可选；按题报数：准备 / 公式栅格化
  /// 阶段报当前题序，Isolate 生成阶段报“正在生成 PDF…”）。
  ///
  /// 快照由本方法内部创建并在结束时 dispose（成功/失败/取消都清理
  /// 整个临时目录）。盘点 guard 硬拒绝或零可印时不建快照，直接抛错。
  Future<PdfExportResult> generate({
    required List<String> ids,
    required List<ExcludedQuestion> excluded,
    required String filterText,
    required String sortText,
    int? circledCount,
    ExportCancellationToken? token,
    ExportVersion variant = ExportVersion.practice,
    void Function(int done, int total, String label)? onProgress,
  }) async {
    final cancelToken = token ?? ExportCancellationToken();
    final frozen = await _freezeExport(
      ids: ids,
      excluded: excluded,
      filterText: filterText,
      sortText: sortText,
      circledCount: circledCount,
      token: cancelToken,
      onProgress: onProgress,
    );
    try {
      return await _generateFromSnapshotOwned(
        snapshot: frozen.snapshot,
        recordsById: frozen.recordsById,
        inventory: frozen.inventory,
        filterText: filterText,
        sortText: sortText,
        routeNotice: frozen.decision.notice,
        token: cancelToken,
        variant: variant,
        onProgress: onProgress,
      );
    } finally {
      // 任务结束（成功/失败/取消）清理整个临时目录。
      await frozen.snapshot.dispose();
    }
  }

  /// 生成两版导出（M2-1：同一快照、同一路线，两次生成）。
  ///
  /// 先冻结一次快照，再按 [versions] 逐版生成（不重新独立查询题目，
  /// 否则题号可能错位）。双文件部分成功语义（P1-5）：每版独立记
  /// 成功/失败，一版失败时保留另一版已验证的结果，不删除、不伪装；
  /// 完成界面按返回的逐版结果展示。取消是整单取消（原样抛
  /// [ExportCancelledException]），不是部分成功。路由判定失败、
  /// guard 硬拒绝、零可印等冻结期失败是整单失败（直接抛错，不产生
  /// 逐版结果）。快照在全部版本生成结束后 dispose。
  Future<TwoVersionExportResult> generateVersions({
    required List<String> ids,
    required List<ExcludedQuestion> excluded,
    required String filterText,
    required String sortText,
    ExportVersionSelection versions =
        const ExportVersionSelection.practiceOnly(),
    int? circledCount,
    ExportCancellationToken? token,
    void Function(int done, int total, String label)? onProgress,
  }) async {
    if (!versions.hasAny) {
      throw ArgumentError('至少选择一个版本');
    }
    final cancelToken = token ?? ExportCancellationToken();
    final frozen = await _freezeExport(
      ids: ids,
      excluded: excluded,
      filterText: filterText,
      sortText: sortText,
      circledCount: circledCount,
      token: cancelToken,
      onProgress: onProgress,
    );
    try {
      VersionExportOutcome? practiceOutcome;
      VersionExportOutcome? answerOutcome;
      if (versions.practice) {
        practiceOutcome = await _runOneVersion(
          frozen: frozen,
          filterText: filterText,
          sortText: sortText,
          token: cancelToken,
          variant: ExportVersion.practice,
          onProgress: onProgress,
        );
      }
      if (versions.answer) {
        answerOutcome = await _runOneVersion(
          frozen: frozen,
          filterText: filterText,
          sortText: sortText,
          token: cancelToken,
          variant: ExportVersion.answer,
          onProgress: onProgress,
        );
      }
      // 报告两版共用：任一版成功即取其报告；两版都失败时用快照层
      // 初步报告（题目级状态为快照初步判定，供失败界面展示题数）。
      final report =
          practiceOutcome?.result?.report ??
          answerOutcome?.result?.report ??
          _preliminaryReport(frozen);
      return TwoVersionExportResult(
        practice: practiceOutcome,
        answer: answerOutcome,
        route: frozen.decision.route,
        report: report,
      );
    } finally {
      await frozen.snapshot.dispose();
    }
  }

  /// 生成一版（generateVersions 内部用）：成功包结果，失败包原因；
  /// 取消原样抛出（整单取消，不是部分成功）。
  Future<VersionExportOutcome> _runOneVersion({
    required _FrozenExport frozen,
    required String filterText,
    required String sortText,
    required ExportCancellationToken token,
    required ExportVersion variant,
    void Function(int done, int total, String label)? onProgress,
  }) async {
    try {
      final result = await _generateFromSnapshotOwned(
        snapshot: frozen.snapshot,
        recordsById: frozen.recordsById,
        inventory: frozen.inventory,
        filterText: filterText,
        sortText: sortText,
        routeNotice: frozen.decision.notice,
        token: token,
        variant: variant,
        onProgress: onProgress,
      );
      return VersionExportOutcome.success(result);
    } on ExportCancelledException {
      rethrow;
    } catch (e) {
      return VersionExportOutcome.failure(_userFacingMessage(e));
    }
  }

  /// 冻结一次导出（generate / generateVersions 共用前奏，与 M1-E
  /// 的 generate() 原行为一致：路由判定 → 读行 → 盘点 → 快照）。
  ///
  /// guard 硬拒绝 / 零可印时不建快照，直接抛错（调用方不产生快照，
  /// 无需 dispose）。快照创建失败时 fromSelection 已清理临时目录。
  Future<_FrozenExport> _freezeExport({
    required List<String> ids,
    required List<ExcludedQuestion> excluded,
    required String filterText,
    required String sortText,
    int? circledCount,
    required ExportCancellationToken token,
    void Function(int done, int total, String label)? onProgress,
  }) async {
    if (ids.isEmpty) {
      throw ArgumentError('请至少选择 1 道题');
    }
    if (ids.length > kExportMaxQuestions) {
      throw ArgumentError('单次最多导出 50 道题');
    }
    await token.checkpoint();
    // 1. 路由判定（读一次，冻结进快照；判定失败 → 整单失败）。
    final decision = await resolveExportRoute(hasApiKey: _hasApiKey);
    // 2. 读行（盘点与快照共用同一批行记录；行不存在 → 占位记录，
    //    盘点与快照均按题目级跳过处理）。
    // D-186：另记一份原始读行结果（含缺题 null），供 step 4 快照
    // 复用——单次读行，取消快照内部的二次 fetch；终态复核的第三次
    // 重读保留。
    final recordsById = <String, ExportQuestionRecord>{};
    final fetchedById = <String, ExportQuestionRecord?>{};
    final selected = <ExportQuestionRecord>[];
    for (var i = 0; i < ids.length; i++) {
      final id = ids[i];
      await token.checkpoint();
      final record = await source.fetchQuestion(id);
      fetchedById[id] = record;
      final effective =
          record ??
          ExportQuestionRecord(
            id: id,
            title: '',
            subjectId: '',
            contentVersion: 0,
          );
      recordsById[id] = effective;
      selected.add(effective);
      onProgress?.call(i + 1, ids.length, '正在准备题目…');
    }
    // 3. 盘点 M1-0（纯数据；guard 硬拒绝 / 零可印 → 不建快照）。
    final inventory = await runInventory(
      decision: decision,
      circledCount: circledCount ?? ids.length,
      selected: selected,
      excluded: excluded,
      source: source,
    );
    if (inventory.guard.isHardReject) {
      throw ExportGuardRejectException(
        '本次导出内容过重（栅格总量约 '
        '${inventory.guard.totalRasterMpx.toStringAsFixed(1)} Mpx，'
        '超过 150 Mpx 上限），已停止生成。请减少题数，或去详情页重新框选。',
        inventory.guard,
      );
    }
    if (!inventory.hasPrintable) {
      throw ExportNoPrintableException(
        '本次没有可导出题目。${_skipSummary(inventory.skipped)}',
      );
    }
    // 4. 快照 M1-1（路由冻结；整单失败时 fromSelection 已清理临时目录）。
    // D-186：把 step 2 的原始读行结果传给 fromSelection，取消快照
    // 内部的二次 fetch（答案在窗口内被改时不再静默导出旧答案）。
    final snapshot = await ExportSnapshot.fromSelection(
      ids: ids,
      excluded: excluded,
      route: decision.route,
      filterText: filterText,
      sortText: sortText,
      source: source,
      tempRoot: tempRoot,
      recordsById: fetchedById,
    );
    return _FrozenExport(
      decision: decision,
      recordsById: recordsById,
      inventory: inventory,
      snapshot: snapshot,
    );
  }

  /// 两版都失败时的初步报告（快照层状态；答案/解析已录入数按冻结
  /// 记录分别判空，空字符串/纯空白视为未录入）。
  IntegrityReport _preliminaryReport(_FrozenExport frozen) {
    var answersRecorded = 0;
    var explanationsRecorded = 0;
    for (final entry in frozen.snapshot.entries) {
      final record = frozen.recordsById[entry.questionId];
      if (record == null) continue;
      if (isAnswerRecorded(
        record.answer,
        pendingRecheck: record.answerPendingRecheck,
      )) {
        answersRecorded++;
      }
      if (isAnswerRecorded(
        record.explanation,
        pendingRecheck: record.answerPendingRecheck,
      )) {
        explanationsRecorded++;
      }
    }
    return IntegrityReport.fromSnapshot(
      frozen.snapshot,
      answersRecorded: answersRecorded,
      explanationsRecorded: explanationsRecorded,
    );
  }

  /// 生成失败的面向用户文案（已知业务异常取其 message；基础设施
  /// 异常与未知异常不把内部细节外露，只给通用文案；P7：PDF 服务
  /// 的兜底须指明 PDF）。
  String _userFacingMessage(Object e) {
    if (e is ExportNoPrintableException) return e.message;
    if (e is ExportGuardRejectException) return e.message;
    if (e is RouteResolutionException) return e.message;
    if (e is SnapshotChangedException) return e.message;
    if (e is SnapshotIntegrityException) return e.message;
    if (e is SnapshotInfrastructureException) return 'PDF 生成失败，请重试。';
    if (e is ArgumentError) return e.message;
    if (e is StateError) return e.message;
    return 'PDF 生成失败，请重试。';
  }

  /// 用已有快照生成一次（M2 两版共用同一快照的基础；M1 验收口径：
  /// 同一快照对象可被两次生成共用，同一对象、同一题序、同一冻结内容）。
  ///
  /// 本方法不拥有快照：不 dispose，调用方负责在全部生成结束后 dispose。
  /// [recordsById] 为快照题的行记录（答案计数与公式原图裁剪用；
  /// 不传时按快照题序从 [source] 重读）。
  /// [variant] 为版本（默认练习版）。
  Future<PdfExportResult> generateFromSnapshot({
    required ExportSnapshot snapshot,
    Map<String, ExportQuestionRecord>? recordsById,
    ExportCancellationToken? token,
    ExportVersion variant = ExportVersion.practice,
    void Function(int done, int total, String label)? onProgress,
  }) async {
    final cancelToken = token ?? ExportCancellationToken();
    // 服务入口复核快照题数 ≤ 50（§2 第 4 点，第二道防线）。
    if (snapshot.questionCount > kExportMaxQuestions) {
      throw ArgumentError('单次最多导出 50 道题');
    }
    final records = recordsById ?? await _fetchRecords(snapshot, cancelToken);
    // 本入口无盘点（调用方已做过盘点）：估算 guard 以快照题重算
    // （与 generate() 的盘点估算同一口径，供偏差记录用），硬拒绝 /
    // 零可印同样拦截（与 generate() 一致，不静默生成）。
    final inventory = await runInventory(
      decision: ExportRouteDecision(
        route: snapshot.route,
        reason: snapshot.route == ExportRoute.c ? '已配置 OCR key' : '未配置 OCR key',
      ),
      circledCount: snapshot.selectedCount,
      selected: [
        for (final id in snapshot.questionIds) records[id]!,
      ],
      excluded: snapshot.excluded,
      source: source,
    );
    if (inventory.guard.isHardReject) {
      throw ExportGuardRejectException(
        '本次导出内容过重（栅格总量约 '
        '${inventory.guard.totalRasterMpx.toStringAsFixed(1)} Mpx，'
        '超过 150 Mpx 上限），已停止生成。请减少题数，或去详情页重新框选。',
        inventory.guard,
      );
    }
    if (!inventory.hasPrintable) {
      throw ExportNoPrintableException(
        '本次没有可导出题目。${_skipSummary(inventory.skipped)}',
      );
    }
    return await _generateFromSnapshotOwned(
      snapshot: snapshot,
      recordsById: records,
      inventory: inventory,
      filterText: snapshot.filterText,
      sortText: snapshot.sortText,
      routeNotice: snapshot.route == ExportRoute.c
          ? const ExportRouteDecision(route: ExportRoute.c, reason: '').notice
          : const ExportRouteDecision(route: ExportRoute.a, reason: '').notice,
      token: cancelToken,
      variant: variant,
      onProgress: onProgress,
    );
  }

  Future<Map<String, ExportQuestionRecord>> _fetchRecords(
    ExportSnapshot snapshot,
    ExportCancellationToken token,
  ) async {
    final records = <String, ExportQuestionRecord>{};
    await token.checkpoint();
    // M3-F：批量重读（生产实现一次读齐，不逐题 N+1）。
    final fetched = await source.fetchQuestions(snapshot.questionIds);
    for (var i = 0; i < snapshot.questionIds.length; i++) {
      final id = snapshot.questionIds[i];
      records[id] =
          fetched[i] ??
          ExportQuestionRecord(
            id: id,
            title: '',
            subjectId: '',
            contentVersion: 0,
          );
    }
    return records;
  }

  /// 快照后生成（generate / generateFromSnapshot / generateVersions
  /// 共用；不 dispose 快照）。
  ///
  /// [variant] 为版本（默认练习版）。答案版时答案区输入取冻结的
  /// [recordsById]（不重新查询题目），经 Isolate 消息传给生成侧。
  Future<PdfExportResult> _generateFromSnapshotOwned({
    required ExportSnapshot snapshot,
    required Map<String, ExportQuestionRecord> recordsById,
    required ExportInventory inventory,
    required String filterText,
    required String sortText,
    required String routeNotice,
    required ExportCancellationToken token,
    ExportVersion variant = ExportVersion.practice,
    void Function(int done, int total, String label)? onProgress,
  }) async {
    await token.checkpoint();
    // 服务入口复核快照题数 ≤ 50（第二道防线；generateFromSnapshot 已
    // 复核，此处再核一次，防直接调内部路径）。
    if (snapshot.questionCount > kExportMaxQuestions) {
      throw ArgumentError('单次最多导出 50 道题');
    }
    // 快照后变零衔接（§5）：公式栅格化与原图裁剪在快照后才可能使题目
    // 变 SKIPPED；若快照后最终可印题数为 0，停止生成，不生成 PDF。
    if (snapshot.printableCount == 0) {
      throw ExportNoPrintableException(
        '本次没有可导出题目。${_snapshotSkipSummary(snapshot)}',
      );
    }
    // 取消时通知栅格化器（飞行中的 toImage() 完成后丢弃结果，
    // 不再启动后续渲染，§8）。
    if (rasterizer != null) {
      unawaited(
        token.whenCancelled.then((_) => rasterizer!.cancel()),
      );
    }
    final exportDateText = _todayText();
    final headerInfo = PdfExportHeaderInfo(
      subjectName: subjectName,
      exportDateText: exportDateText,
    );
    // 答案版元数据标题带版本后缀（阅读器里可区分两版；文件名后缀
    // 另由 export_filename.dart 定）。
    final metadata = PdfExportMetadata(
      title: variant == ExportVersion.answer
          ? '错题本导出 · $subjectName（答案版）'
          : '错题本导出 · $subjectName',
    );
    // 答案区输入（冻结值，不重新查询题目；练习版不传）。
    final answerSources = variant == ExportVersion.answer
        ? answerSourcesFromRecords(recordsById.values)
        : const <AnswerSourceData>[];

    // C 路线：逐题栅格化公式（主 Isolate，逐题检查点）→ guard 实际值
    // 复核 → 分页规划（主 Isolate，TextPainter）。
    CPagePlan? cPlan;
    List<CBuildQuestion>? cQuestions;
    Map<String, QuestionFormulaVerdict>? cVerdicts;
    Set<String>? cFormulaSkipped;
    Map<String, bool>? cExtraFigureMissing;
    if (snapshot.route == ExportRoute.c) {
      final raster = await _rasterizeSnapshotFormulas(
        snapshot: snapshot,
        recordsById: recordsById,
        token: token,
        onProgress: onProgress,
      );
      cVerdicts = raster.verdicts;
      cFormulaSkipped = raster.skippedQuestionIds;
      // guard 实际值复核（D-181）：快照完成后、生成开始前，用实际
      // 栅格化后的像素数复核一次；超硬阈值 → 中止生成。
      final actualItems = await _actualGuardItemsC(
        snapshot: snapshot,
        verdicts: cVerdicts,
        skippedQuestionIds: cFormulaSkipped,
      );
      final actualGuard = ContentGuard.evaluate(
        actualItems,
        isEstimate: false,
      );
      if (actualGuard.isHardReject) {
        throw ExportGuardRejectException(
          '本次导出内容过重（实际栅格总量约 '
          '${actualGuard.totalRasterMpx.toStringAsFixed(1)} Mpx，'
          '超过 150 Mpx 上限），已停止生成。请减少题数，或去详情页重新框选。',
          actualGuard,
        );
      }
      // 快照后变零衔接（公式级）：栅格化后可印题变 0 → 停止生成。
      final printableAfterFormulas =
          snapshot.entries
              .where(
                (e) =>
                    e.outcome == SnapshotOutcome.ready &&
                    !raster.skippedQuestionIds.contains(e.questionId),
              )
              .length;
      if (printableAfterFormulas == 0) {
        throw ExportNoPrintableException(
          '本次没有可导出题目（全部题目因公式无法呈现被跳过）。',
        );
      }
      final planned = await _planC(
        snapshot: snapshot,
        recordsById: recordsById,
        verdicts: cVerdicts,
        skippedQuestionIds: cFormulaSkipped,
        token: token,
      );
      cPlan = planned.plan;
      cQuestions = planned.questions;
      cExtraFigureMissing = planned.extraFigureMissing;
      final info = PdfExportInfo(
        filterText: filterText,
        questionCount: cQuestions.length,
        exportDateText: exportDateText,
        sortText: sortText,
        routeText: routeNotice,
      );
      // Isolate 内按题生成无逐题回调：报“正在生成 PDF…”（题目已全部
      // 准备就绪，进度停在 N / N 含义为“已准备 N / N 题，正在生成”）。
      onProgress?.call(
        snapshot.selectedCount,
        snapshot.selectedCount,
        '正在生成 PDF…',
      );
      final output = await _runGenerationInIsolate(
        route: ExportRoute.c,
        tempDirPath: snapshot.tempDir.path,
        cPlan: cPlan,
        cQuestions: cQuestions,
        metadata: metadata,
        headerInfo: headerInfo,
        info: info,
        token: token,
        variant: variant,
        answerSources: answerSources,
      );
      return _finishC(
        snapshot: snapshot,
        recordsById: recordsById,
        inventory: inventory,
        actualGuard: actualGuard,
        output: output,
        verdicts: cVerdicts,
        formulaSkipped: cFormulaSkipped,
        extraFigureMissing: cExtraFigureMissing,
        variant: variant,
      );
    }

    // A 路线：guard 实际值复核（快照切片已是 300 DPI 限制后尺寸，
    // 实际值 = 上限后像素数；增强不改变像素数）。
    final actualItemsA = <GuardRasterItem>[
      for (final e in snapshot.entries)
        if (e.outcome == SnapshotOutcome.ready && e.sliceCopy != null)
          GuardRasterItem(
            questionId: e.questionId,
            title: e.title,
            rasterMpx:
                ContentGuard.cappedRasterPixels(
                  widthPx: e.sliceCopy!.dimensions.width,
                  heightPx: e.sliceCopy!.dimensions.height,
                  displayWidthPt: PdfExportGeometry.contentWidthPt,
                ) /
                1000000,
            isEstimate: false,
          ),
    ];
    final actualGuardA = ContentGuard.evaluate(
      actualItemsA,
      isEstimate: false,
    );
    if (actualGuardA.isHardReject) {
      throw ExportGuardRejectException(
        '本次导出内容过重（实际栅格总量约 '
        '${actualGuardA.totalRasterMpx.toStringAsFixed(1)} Mpx，'
        '超过 150 Mpx 上限），已停止生成。请减少题数，或去详情页重新框选。',
        actualGuardA,
      );
    }
    final infoA = PdfExportInfo(
      filterText: filterText,
      // A 路线印出题 = 可印图像题 + BROKEN 占位（准备阶段门禁跳过
      // 仅在 excludeLowDpi 勾选时发生，默认不勾，计数即此数）。
      questionCount: snapshot.printableCount + snapshot.brokenCount,
      exportDateText: exportDateText,
      sortText: sortText,
      routeText: routeNotice,
    );
    // 同 C 路线：Isolate 内无逐题回调，报“正在生成 PDF…”。
    onProgress?.call(
      snapshot.selectedCount,
      snapshot.selectedCount,
      '正在生成 PDF…',
    );
    // M3-F：A 路线逐题来源行（主 Isolate 用冻结记录拼好，经消息传进
    // 生成 Isolate；与 C 路线 _planC 用 sourceTextFor 的口径一致）。
    // 答案版两次构建共用同一份消息，题目区来源行同一口径。
    final aSourceTexts = <String, String>{
      for (final entry in snapshot.entries)
        if (recordsById[entry.questionId] != null)
          entry.questionId:
              sourceTextFor?.call(recordsById[entry.questionId]!) ?? '',
    };
    final outputA = await _runGenerationInIsolate(
      route: ExportRoute.a,
      snapshot: snapshot,
      tempDirPath: snapshot.tempDir.path,
      metadata: metadata,
      headerInfo: headerInfo,
      info: infoA,
      excludeLowDpi: excludeLowDpi,
      excludeBelowDpi: excludeBelowDpi,
      token: token,
      variant: variant,
      answerSources: answerSources,
      aSourceTexts: aSourceTexts,
    );
    return _finishA(
      snapshot: snapshot,
      recordsById: recordsById,
      inventory: inventory,
      actualGuard: actualGuardA,
      output: outputA,
      variant: variant,
    );
  }

  // ------------------------------------------------------------------
  // C 路线：公式栅格化 + 分页规划（主 Isolate）。
  // ------------------------------------------------------------------

  /// 逐题栅格化快照内全部公式（主 Isolate；每题前检查点）。
  ///
  /// 返回每题的裁决与因公式失败整题跳过的题 ID。任一公式渲染失败
  /// 且原图裁剪亦失败 → 整题 SKIPPED（其余公式/正文/图块/答案再完整
  /// 也不印，§8）；任一公式为原图 → 该题 PARTIAL。
  Future<_CRasterWork> _rasterizeSnapshotFormulas({
    required ExportSnapshot snapshot,
    required Map<String, ExportQuestionRecord> recordsById,
    required ExportCancellationToken token,
    void Function(int done, int total, String label)? onProgress,
  }) async {
    final verdicts = <String, QuestionFormulaVerdict>{};
    final skipped = <String>{};
    for (var qi = 0; qi < snapshot.entries.length; qi++) {
      final entry = snapshot.entries[qi];
      if (entry.outcome != SnapshotOutcome.ready ||
          entry.ocrContent == null) {
        continue;
      }
      // 每题生成前检查点（让出执行权再检查标志，§7）。
      await token.checkpoint();
      final record = recordsById[entry.questionId]!;
      final verdict = await _rasterizeOneQuestion(
        entry: entry,
        questionIndex: qi,
        record: record,
        tempDir: snapshot.tempDir,
        token: token,
      );
      verdicts[entry.questionId] = verdict;
      if (verdict.skipQuestion) {
        skipped.add(entry.questionId);
      }
      onProgress?.call(
        qi + 1,
        snapshot.selectedCount,
        '正在处理公式…',
      );
    }
    return _CRasterWork(verdicts: verdicts, skippedQuestionIds: skipped);
  }

  /// 一题多公式栅格化 + 降级链（§8）。
  ///
  /// 公式按块序列文档顺序编号（`q<题序>-f<序号>`）；原图裁剪的
  /// formulaIndex 取同一序号（cropFormulaImageBytes 按 ocrRaw 的
  /// 公式框列表取框，与块序列顺序一致是本包的前提假设，见报告）。
  Future<QuestionFormulaVerdict> _rasterizeOneQuestion({
    required SnapshotQuestionEntry entry,
    required int questionIndex,
    required ExportQuestionRecord record,
    required Directory tempDir,
    required ExportCancellationToken token,
  }) async {
    final ocr = entry.ocrContent!;
    final requests = <FormulaRasterRequest>[];
    void collect(List<QuestionContentBlock> blocks) {
      for (final block in blocks) {
        if (block is FormulaBlock) {
          requests.add(
            FormulaRasterRequest(
              formulaId: 'q$questionIndex-f${requests.length}',
              latex: block.latex,
              displayMode: block.displayMode,
            ),
          );
        } else if (block is TableBlock) {
          for (final row in block.rows) {
            for (final cell in row) {
              collect(cell.children);
            }
          }
        }
      }
    }

    collect(ocr.blocks);
    if (requests.isEmpty) {
      return const QuestionFormulaVerdict(outcomes: []);
    }
    // 切片字节按需读一次（锁内读；裁剪只读快照时刻的字节，不碰共享文件）。
    Uint8List? cachedSlice;
    Future<Uint8List?> cropOriginal(int formulaIndex) async {
      try {
        cachedSlice ??= await SliceWriteGuard.instance.withLock(() async {
          final builder = BytesBuilder();
          await for (final chunk in source.openSliceBytes(record)) {
            builder.add(chunk);
          }
          return builder.takeBytes();
        });
        return cropFormulaImageBytes(
          sliceBytes: cachedSlice!,
          ocrRaw: record.ocrRaw,
          formulaIndex: formulaIndex,
        );
      } catch (_) {
        return null;
      }
    }

    final raster = rasterizer;
    if (raster == null) {
      // 无栅格化器（无 Widget 环境）：纯裁剪降级链。
      return _rasterizeByCropOnly(
        requests: requests,
        tempDir: tempDir,
        cropOriginal: cropOriginal,
      );
    }
    try {
      return await raster.rasterizeQuestionFormulas(
        requests: requests,
        tempDir: tempDir,
        cropOriginal: cropOriginal,
      );
    } on FormulaRasterException catch (e) {
      if (e.kind == FormulaRasterFailureKind.cancelled) {
        throw const ExportCancelledException();
      }
      rethrow;
    }
  }

  /// 无栅格化器时的纯裁剪降级链（与 [FormulaRasterizer] 同口径）：
  /// 裁剪成功 → 原图（PARTIAL），裁剪失败 → 失败（整题 SKIPPED）。
  Future<QuestionFormulaVerdict> _rasterizeByCropOnly({
    required List<FormulaRasterRequest> requests,
    required Directory tempDir,
    required Future<Uint8List?> Function(int formulaIndex) cropOriginal,
  }) async {
    final outcomes = <FormulaQuestionOutcome>[];
    for (var i = 0; i < requests.length; i++) {
      final request = requests[i];
      final cropped = await cropOriginal(i);
      if (cropped == null) {
        outcomes.add(
          FormulaQuestionOutcome(
            formulaId: request.formulaId,
            kind: FormulaQuestionOutcomeKind.failed,
          ),
        );
        continue;
      }
      final displayWidth = request.displayMode
          ? PdfExportGeometry.contentWidthPt
          : _inlineDisplayWidthPt(request.fontSizePt);
      final capped = capPngTo300Dpi(cropped, displayWidth);
      if (capped == null) {
        outcomes.add(
          FormulaQuestionOutcome(
            formulaId: request.formulaId,
            kind: FormulaQuestionOutcomeKind.failed,
          ),
        );
        continue;
      }
      final decoded = _decodePng(capped);
      if (decoded == null) {
        outcomes.add(
          FormulaQuestionOutcome(
            formulaId: request.formulaId,
            kind: FormulaQuestionOutcomeKind.failed,
          ),
        );
        continue;
      }
      final safeId = request.formulaId.replaceAll(
        RegExp(r'[^A-Za-z0-9._-]'),
        '_',
      );
      final formulasDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}formulas',
      );
      if (!formulasDir.existsSync()) {
        formulasDir.createSync(recursive: true);
      }
      final target = File(
        '${formulasDir.path}${Platform.pathSeparator}$safeId-orig.png',
      );
      try {
        target.writeAsBytesSync(capped);
      } on FileSystemException {
        outcomes.add(
          FormulaQuestionOutcome(
            formulaId: request.formulaId,
            kind: FormulaQuestionOutcomeKind.failed,
          ),
        );
        continue;
      }
      outcomes.add(
        FormulaQuestionOutcome(
          formulaId: request.formulaId,
          kind: FormulaQuestionOutcomeKind.original,
          result: FormulaRasterResult(
            formulaId: request.formulaId,
            relativePath: 'formulas/$safeId-orig.png',
            pixelWidth: decoded.width,
            pixelHeight: decoded.height,
            logicalWidthPt: displayWidth,
            logicalHeightPt:
                decoded.height / decoded.width * displayWidth,
            effectiveDpi: ContentGuard.effectiveDpi(
              widthPx: decoded.width,
              displayWidthPt: displayWidth,
            ),
            shrunk: false,
            isOriginal: true,
          ),
        ),
      );
    }
    return QuestionFormulaVerdict(outcomes: outcomes);
  }

  /// 行内公式降级图的显示宽（pt）：与栅格化器同口径（正文字号高度
  /// 估算宽高比 4:1，见 content_guard 盘点估算）。
  double _inlineDisplayWidthPt(double fontSizePt) {
    final heightPx = fontSizePt / 72 * 300;
    return heightPx * 4 / 300 * 72;
  }

  /// PNG 解码（只取尺寸；解不出返回 null，调用方按裁剪失败处理）。
  ({int width, int height})? _decodePng(Uint8List bytes) {
    final dims = readPngDimensions(bytes);
    if (dims == null) return null;
    return (width: dims.width, height: dims.height);
  }

  /// C 路线 guard 实际值复核的输入（D-181/C-13）：公式位图（栅格化后
  /// 实际像素数）+ 图块裁剪（300 DPI 限制后像素数）。不印的题不计入。
  Future<List<GuardRasterItem>> _actualGuardItemsC({
    required ExportSnapshot snapshot,
    required Map<String, QuestionFormulaVerdict> verdicts,
    required Set<String> skippedQuestionIds,
  }) async {
    final items = <GuardRasterItem>[];
    for (final entry in snapshot.entries) {
      if (entry.outcome != SnapshotOutcome.ready ||
          skippedQuestionIds.contains(entry.questionId)) {
        continue;
      }
      var pixels = verdicts[entry.questionId]?.totalRasterPixels ?? 0;
      final ocr = entry.ocrContent;
      if (ocr != null) {
        for (final figure in ocr.figures) {
          if (!figure.cropped) continue;
          final dims = await _tempPngDimensions(
            snapshot.tempDir,
            figure.tempRelativePath,
          );
          if (dims == null) continue;
          final size = _figureDisplaySize(dims.width, dims.height);
          pixels += ContentGuard.cappedRasterPixels(
            widthPx: dims.width,
            heightPx: dims.height,
            displayWidthPt: size.widthPt,
          );
        }
      }
      items.add(
        GuardRasterItem(
          questionId: entry.questionId,
          title: entry.title,
          rasterMpx: pixels / 1000000,
          isEstimate: false,
        ),
      );
    }
    return items;
  }

  /// 读任务临时目录内一张 PNG 的 IHDR 尺寸（只读头 64 字节，不解码）。
  Future<PngDimensions?> _tempPngDimensions(
    Directory tempDir,
    String relativePath,
  ) async {
    try {
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}'
        '${relativePath.replaceAll('/', Platform.pathSeparator)}',
      );
      if (!file.existsSync()) return null;
      final builder = BytesBuilder();
      await for (final chunk in file.openRead(0, 64)) {
        builder.add(chunk);
      }
      return readPngDimensions(builder.takeBytes());
    } catch (_) {
      return null;
    }
  }

  /// 图块显示尺寸（pt）：300 DPI 自然尺寸，上限内容区宽（与分页
  /// 转换同一口径；分页器对超高原子块再做等比缩小，见附录 C.4）。
  ({double widthPt, double heightPt}) _figureDisplaySize(
    int widthPx,
    int heightPx,
  ) {
    if (widthPx <= 0 || heightPx <= 0) {
      return (widthPt: 0, heightPt: 0);
    }
    final naturalWidthPt = widthPx / 300 * 72;
    final widthPt = math.min(
      PdfExportGeometry.contentWidthPt,
      naturalWidthPt,
    );
    return (widthPt: widthPt, heightPt: heightPx / widthPx * widthPt);
  }

  /// C 路线分页规划（主 Isolate）：块序列 → 分页器 → 构建输入。
  Future<_CPlanned> _planC({
    required ExportSnapshot snapshot,
    required Map<String, ExportQuestionRecord> recordsById,
    required Map<String, QuestionFormulaVerdict> verdicts,
    required Set<String> skippedQuestionIds,
    required ExportCancellationToken token,
  }) async {
    await token.checkpoint();
    final splitter = TextPainterSplitter();
    await splitter.ensureFontLoaded();
    final paginable = <CPaginableQuestion>[];
    final buildQuestions = <CBuildQuestion>[];
    final extraFigureMissing = <String, bool>{};
    var displayNumber = 0;
    for (var qi = 0; qi < snapshot.entries.length; qi++) {
      final entry = snapshot.entries[qi];
      if (entry.outcome != SnapshotOutcome.ready ||
          entry.ocrContent == null ||
          skippedQuestionIds.contains(entry.questionId)) {
        continue;
      }
      await token.checkpoint();
      displayNumber++;
      final record = recordsById[entry.questionId]!;
      final verdict = verdicts[entry.questionId]!;
      final converted = await _convertCQuestion(
        entry: entry,
        questionIndex: qi,
        verdict: verdict,
        tempDir: snapshot.tempDir,
      );
      extraFigureMissing[entry.questionId] = converted.figureMissing;
      final sourceText = sourceTextFor?.call(record) ?? '';
      paginable.add(
        CPaginableQuestion(
          questionIndex: qi,
          displayNumber: displayNumber,
          blocks: converted.layoutBlocks,
          sourceText: sourceText,
        ),
      );
      final warnings = <String>[
        ...entry.warnings,
        if (converted.hasOriginalFormula && !entry.warnings.contains('公式为原图'))
          '公式为原图',
        if (converted.hasShrunkFormula &&
            !entry.warnings.contains('公式已缩小'))
          '公式已缩小',
        if (converted.figureMissing && !entry.warnings.contains('图块缺失'))
          '图块缺失',
      ];
      buildQuestions.add(
        CBuildQuestion(
          questionIndex: qi,
          questionId: entry.questionId,
          title: entry.title,
          sourceText: sourceText,
          warnings: warnings,
        ),
      );
    }
    final paginator = CTextPaginator(splitter: splitter);
    final plan = paginator.paginate(paginable);
    final violations = validatePlan(plan);
    if (violations.isNotEmpty) {
      throw StateError('分页规划自检失败：${violations.join('；')}');
    }
    return _CPlanned(
      plan: plan,
      questions: buildQuestions,
      extraFigureMissing: extraFigureMissing,
    );
  }

  /// 快照块序列 → 分页输入（CLayoutBlock）。
  ///
  /// - TextBlock / CodeBlock / HeadingBlock → 段落文本；
  /// - 行内公式 → 段落内 [CInlineFormula]（栅格化结果的引用与尺寸）；
  /// - 独立公式 / 图块 → 原子块（整块移页）；
  /// - ImageFallbackBlock → 不印（§8：导出不采用整题切片回退）；
  /// - TableBlock → 单元格展平进行内文本（公式随行内处理，图块同上）。
  Future<_CConverted> _convertCQuestion({
    required SnapshotQuestionEntry entry,
    required int questionIndex,
    required QuestionFormulaVerdict verdict,
    required Directory tempDir,
  }) async {
    final ocr = entry.ocrContent!;
    final byId = {
      for (final outcome in verdict.outcomes) outcome.formulaId: outcome,
    };
    var formulaCounter = 0;
    final layoutBlocks = <CLayoutBlock>[];
    var textBuf = StringBuffer();
    var inlineFormulas = <CInlineFormula>[];
    var hasOriginal = false;
    var hasShrunk = false;
    var figureMissing = false;

    void flushParagraph() {
      if (textBuf.isEmpty && inlineFormulas.isEmpty) return;
      layoutBlocks.add(
        CLayoutParagraph(
          CParagraph(
            text: textBuf.toString(),
            inlineFormulas: List.of(inlineFormulas),
          ),
        ),
      );
      textBuf = StringBuffer();
      inlineFormulas = <CInlineFormula>[];
    }

    Future<void> visitBlocks(List<QuestionContentBlock> blocks) async {
      for (final block in blocks) {
        switch (block) {
          case TextBlock(:final text):
            textBuf.write(text);
          case HeadingBlock(:final text):
            flushParagraph();
            textBuf.write(text);
            flushParagraph();
          case CodeBlock(:final code):
            flushParagraph();
            textBuf.write(code);
            flushParagraph();
          case FormulaBlock(:final displayMode):
            final id = 'q$questionIndex-f${formulaCounter++}';
            final outcome = byId[id];
            final result = outcome?.result;
            if (result == null) {
              // 无裁决结果的公式（不应发生：栅格化覆盖全部公式块）→
              // 按失败处理：本转换不抛错，上游已按 verdict.skipQuestion
              // 把整题跳过；此处防御性跳过该公式块。
              continue;
            }
            if (outcome!.kind == FormulaQuestionOutcomeKind.original) {
              hasOriginal = true;
            }
            if (result.shrunk) hasShrunk = true;
            if (displayMode) {
              flushParagraph();
              layoutBlocks.add(
                CLayoutAtomic(
                  CAtomicBlock(
                    kind: CAtomicKind.displayFormula,
                    ref: result.relativePath,
                    widthPt: result.logicalWidthPt,
                    heightPt: result.logicalHeightPt,
                    isOriginal: result.isOriginal,
                    shrunk: result.shrunk,
                  ),
                ),
              );
            } else {
              inlineFormulas.add(
                CInlineFormula(
                  offset: textBuf.length,
                  widthPt: result.logicalWidthPt,
                  heightPt: result.logicalHeightPt,
                  formulaId: id,
                  ref: result.relativePath,
                  // D-188：行内公式同样携带原图/缩小标记（与独立公式
                  // 的 CAtomicBlock 同口径），供 _collectResults 汇总
                  // 完整性状态；否则只有行内公式降级的题误判 COMPLETE。
                  isOriginal: result.isOriginal,
                  shrunk: result.shrunk,
                  // 十八批 P1：透传栅格化器量得的基线偏移（原图降级
                  // 为 null，构建器按旧居中启发式放）。
                  baselineOffsetPt: result.baselineOffsetPt,
                ),
              );
            }
          case FigureBlock(:final cropPath):
            flushParagraph();
            final dims = await _tempPngDimensions(tempDir, cropPath);
            if (dims == null) {
              figureMissing = true;
              continue;
            }
            final size = _figureDisplaySize(dims.width, dims.height);
            layoutBlocks.add(
              CLayoutAtomic(
                CAtomicBlock(
                  kind: CAtomicKind.figure,
                  ref: cropPath,
                  widthPt: size.widthPt,
                  heightPt: size.heightPt,
                ),
              ),
            );
          case TableBlock(:final rows):
            flushParagraph();
            for (var ri = 0; ri < rows.length; ri++) {
              final row = rows[ri];
              for (var ci = 0; ci < row.length; ci++) {
                await visitBlocks(row[ci].children);
                if (ci < row.length - 1 && textBuf.isNotEmpty) {
                  textBuf.write('  ');
                }
              }
              if (ri < rows.length - 1 && textBuf.isNotEmpty) {
                textBuf.write('\n');
              }
            }
            flushParagraph();
          case ImageFallbackBlock():
            // 导出不印（§8：不采用整题切片回退，不得印无图可指的图块）。
            break;
        }
      }
    }

    await visitBlocks(ocr.blocks);
    flushParagraph();
    return _CConverted(
      layoutBlocks: layoutBlocks,
      hasOriginalFormula: hasOriginal,
      hasShrunkFormula: hasShrunk,
      figureMissing: figureMissing,
    );
  }

  // ------------------------------------------------------------------
  // 生成 Isolate（构建 + save）。
  // ------------------------------------------------------------------

  /// 在后台 Isolate 内构建文档并 `save()`（C-7：唯一保存入口
  /// `savePdf`，必须 await；完成前不得发布文件）。
  ///
  /// 取消时 kill Isolate（Isolate.run 无法强制终止，故用
  /// Isolate.spawn + 端口），编排层清理整个临时目录，不留半截 PDF。
  Future<_IsolateOutput> _runGenerationInIsolate({
    required ExportRoute route,
    ExportSnapshot? snapshot,
    required String tempDirPath,
    CPagePlan? cPlan,
    List<CBuildQuestion>? cQuestions,
    required PdfExportMetadata metadata,
    required PdfExportHeaderInfo headerInfo,
    required PdfExportInfo info,
    bool excludeLowDpi = false,
    double excludeBelowDpi = kClarityWarnDpi,
    required ExportCancellationToken token,
    ExportVersion variant = ExportVersion.practice,
    List<AnswerSourceData> answerSources = const [],
    Map<String, String> aSourceTexts = const {},
  }) async {
    final fontBytes = await _fontBytesLoader();
    await token.checkpoint();
    final receivePort = ReceivePort();
    Isolate? isolate;
    try {
      final message = <String, Object?>{
        'reply': receivePort.sendPort,
        'route': route.name,
        'fontBytes': fontBytes,
        'tempDirPath': tempDirPath,
        'title': metadata.title,
        'author': metadata.author,
        'creator': metadata.creator,
        'producer': metadata.producer,
        'subject': metadata.subject,
        'keywords': metadata.keywords,
        'subjectName': headerInfo.subjectName,
        'exportDateText': headerInfo.exportDateText,
        'filterText': info.filterText,
        'questionCount': info.questionCount,
        'sortText': info.sortText,
        'routeText': info.routeText,
        'excludeLowDpi': excludeLowDpi,
        'excludeBelowDpi': excludeBelowDpi,
        'variant': variant.name,
        'answerSources': [
          for (final s in answerSources)
            <String, Object?>{
              'questionId': s.questionId,
              'answer': s.answer,
              'explanation': s.explanation,
              'pendingRecheck': s.answerPendingRecheck,
            },
        ],
        if (snapshot != null) 'snapshot': snapshot,
        if (cPlan != null) 'cPlan': cPlan,
        if (cQuestions != null) 'cQuestions': cQuestions,
        // M3-F：A 路线逐题来源行（questionId → “学科 / 文件夹 / 考试名”）。
        'aSourceTexts': aSourceTexts,
      };
      isolate = await Isolate.spawn(_pdfExportIsolateEntry, message);
      final replyFuture = receivePort.first.then(
        (m) => m as Map<String, Object?>,
      );
      // D-183：看门狗——回包等待加 60 s 超时（正常生成远低于此）。
      // 超时即 kill 子 Isolate 并明确报错，不静默挂起、不留半截 PDF。
      final reply = await Future.any([
        replyFuture,
        token.whenCancelled.then(
          (_) => throw const ExportCancelledException(),
        ),
      ]).timeout(
        kPdfGenerationWatchdogTimeout,
        onTimeout: () =>
            throw TimeoutException('PDF 生成超时，已中止，未产生文件'),
      );
      if (reply['ok'] != true) {
        throw _isolateErrorToException(reply);
      }
      final bytes = reply['bytes'] as Uint8List;
      if (bytes.isEmpty || !_startsWithPdfHeader(bytes)) {
        throw StateError('生成的 PDF 文件无效（文件为空或内容不是 PDF），请重试。');
      }
      return _IsolateOutput(
        bytes: bytes,
        totalPages: reply['totalPages'] as int,
        questionPages: [
          for (final m in reply['questionPages'] as List)
            ExportQuestionPage(
              questionId: (m as Map)['questionId'] as String,
              displayNumber: m['displayNumber'] as int,
              pages: List<int>.from(m['pages'] as List),
            ),
        ],
        aQuestions: (reply['aQuestions'] as List?)
            ?.cast<AQuestionBuildResult>(),
        cQuestions: (reply['cQuestions'] as List?)
            ?.cast<CQuestionBuildResult>(),
      );
    } on TimeoutException {
      // 看门狗超时（D-183）：kill 子 Isolate，明确报错；落盘在回包
      // 之后才做，超时前未产生任何文件。
      isolate?.kill(priority: Isolate.immediate);
      throw StateError('PDF 生成超时，已中止，未产生文件');
    } on ExportCancelledException {
      isolate?.kill(priority: Isolate.immediate);
      rethrow;
    } finally {
      receivePort.close();
    }
  }

  /// Isolate 侧的错误还原为调用方的异常类型（只传 kind + 文案，
  /// 不含公式内容）。返回 Object（StateError 是 Error 不是 Exception，
  /// 不能统一成 Exception 返回类型）。
  Object _isolateErrorToException(Map<String, Object?> reply) {
    final kind = reply['kind'] as String? ?? 'other';
    final message = reply['message'] as String? ?? 'PDF 生成失败';
    return switch (kind) {
      'noPrintable' => ExportNoPrintableException(message),
      'integrity' => SnapshotIntegrityException(message),
      'infrastructure' => SnapshotInfrastructureException(message),
      'argument' => ArgumentError(message),
      _ => StateError(message),
    };
  }

  bool _startsWithPdfHeader(Uint8List bytes) {
    if (bytes.length < 5) return false;
    return bytes[0] == 0x25 && // %
        bytes[1] == 0x50 && // P
        bytes[2] == 0x44 && // D
        bytes[3] == 0x46 && // F
        bytes[4] == 0x2D; // -
  }

  // ------------------------------------------------------------------
  // 收尾：完整性报告（C-14 计数守恒核对）。
  // ------------------------------------------------------------------

  PdfExportResult _finishC({
    required ExportSnapshot snapshot,
    required Map<String, ExportQuestionRecord> recordsById,
    required ExportInventory inventory,
    required ContentGuardResult actualGuard,
    required _IsolateOutput output,
    required Map<String, QuestionFormulaVerdict> verdicts,
    required Set<String> formulaSkipped,
    required Map<String, bool> extraFigureMissing,
    ExportVersion variant = ExportVersion.practice,
  }) {
    final byId = {
      for (final q in output.cQuestions ?? const <CQuestionBuildResult>[])
        q.questionId: q,
    };
    final entries = <IntegrityEntry>[];
    for (final entry in snapshot.entries) {
      if (entry.outcome == SnapshotOutcome.skipped ||
          formulaSkipped.contains(entry.questionId)) {
        entries.add(
          IntegrityEntry(
            questionId: entry.questionId,
            title: entry.title,
            status: IntegrityStatus.skipped,
            warnings: List.of(entry.warnings),
            skipReason: entry.outcome == SnapshotOutcome.skipped
                ? entry.skipReason
                : '公式无法呈现',
          ),
        );
        continue;
      }
      final build = byId[entry.questionId]!;
      final ocr = entry.ocrContent!;
      entries.add(
        IntegrityEntry(
          questionId: entry.questionId,
          title: entry.title,
          status: classifyC(
            printable: true,
            formulaOriginal: build.hasOriginalFormula,
            figureMissing:
                ocr.hasFigureMissing ||
                (extraFigureMissing[entry.questionId] ?? false),
            optionUncertain: ocr.hasOptionUncertain,
            contentParseFallback: ocr.contentParseFallback,
          ),
          warnings: List.of(build.warnings),
        ),
      );
    }
    final report = _buildReport(
      snapshot: snapshot,
      recordsById: recordsById,
      entries: entries,
    );
    return PdfExportResult(
      pdfBytes: output.bytes,
      report: report,
      route: ExportRoute.c,
      totalPages: output.totalPages,
      questionPages: output.questionPages,
      estimatedGuard: inventory.guard,
      actualGuard: actualGuard,
      guardDeviation: ContentGuard.compareEstimateVsActual(
        estimatedMpx: inventory.guard.totalRasterMpx,
        actualMpx: actualGuard.totalRasterMpx,
      ),
      variant: variant,
    );
  }

  PdfExportResult _finishA({
    required ExportSnapshot snapshot,
    required Map<String, ExportQuestionRecord> recordsById,
    required ExportInventory inventory,
    required ContentGuardResult actualGuard,
    required _IsolateOutput output,
    ExportVersion variant = ExportVersion.practice,
  }) {
    final aResult = _ABuildResultView(questions: output.aQuestions ?? const []);
    final entries = aResult.toIntegrityEntries();
    final report = _buildReport(
      snapshot: snapshot,
      recordsById: recordsById,
      entries: entries,
    );
    return PdfExportResult(
      pdfBytes: output.bytes,
      report: report,
      route: ExportRoute.a,
      totalPages: output.totalPages,
      questionPages: output.questionPages,
      estimatedGuard: inventory.guard,
      actualGuard: actualGuard,
      guardDeviation: ContentGuard.compareEstimateVsActual(
        estimatedMpx: inventory.guard.totalRasterMpx,
        actualMpx: actualGuard.totalRasterMpx,
      ),
      variant: variant,
    );
  }

  /// 完整性报告组装（答案/解析已录入数按实际答案版数据覆盖：
  /// 答案/解析分别判空，空字符串/纯空白视为未录入，
  /// `answerPendingRecheck` 置位期间旧值无效；练习版报告也按此口径填）。
  IntegrityReport _buildReport({
    required ExportSnapshot snapshot,
    required Map<String, ExportQuestionRecord> recordsById,
    required List<IntegrityEntry> entries,
  }) {
    var answersRecorded = 0;
    var explanationsRecorded = 0;
    for (final entry in snapshot.entries) {
      final record = recordsById[entry.questionId];
      if (record == null) continue;
      if (isAnswerRecorded(
        record.answer,
        pendingRecheck: record.answerPendingRecheck,
      )) {
        answersRecorded++;
      }
      if (isAnswerRecorded(
        record.explanation,
        pendingRecheck: record.answerPendingRecheck,
      )) {
        explanationsRecorded++;
      }
    }
    final report = IntegrityReport(
      route: snapshot.route,
      selectedCount: snapshot.selectedCount,
      snapshotCount: snapshot.questionCount,
      excludedCount: snapshot.excluded.length,
      entries: entries,
      answersRecorded: answersRecorded,
      answersTotal: snapshot.questionCount,
      explanationsRecorded: explanationsRecorded,
      explanationsTotal: snapshot.questionCount,
    );
    // 计数守恒核对（C-14）：对不上即整单失败，不返回半截结果。
    report.checkConservationOrThrow();
    return report;
  }

  String _todayText() {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  String _skipSummary(List<SkipEntry> skipped) {
    if (skipped.isEmpty) return '';
    final reasons = <String, int>{};
    for (final s in skipped) {
      reasons[s.reason] = (reasons[s.reason] ?? 0) + 1;
    }
    return reasons.entries
        .map((e) => '${e.key} ${e.value} 道')
        .join('，');
  }

  String _snapshotSkipSummary(ExportSnapshot snapshot) {
    final reasons = <String, int>{};
    for (final e in snapshot.entries) {
      if (e.outcome == SnapshotOutcome.skipped) {
        final reason = e.skipReason ?? '跳过';
        reasons[reason] = (reasons[reason] ?? 0) + 1;
      }
    }
    if (reasons.isEmpty) return '';
    return reasons.entries
        .map((e) => '${e.key} ${e.value} 道')
        .join('，');
  }
}

/// C 路线一题栅格化工作的汇总。
class _CRasterWork {
  const _CRasterWork({
    required this.verdicts,
    required this.skippedQuestionIds,
  });

  /// 每题裁决（questionId → 裁决）。
  final Map<String, QuestionFormulaVerdict> verdicts;

  /// 因公式失败整题跳过的题 ID。
  final Set<String> skippedQuestionIds;
}

/// 一次冻结的导出（_freezeExport 的产物：路由判定 + 行记录 +
/// 盘点 + 快照；generate / generateVersions 共用，行为与 M1-E
/// 的 generate() 前奏一致）。
class _FrozenExport {
  const _FrozenExport({
    required this.decision,
    required this.recordsById,
    required this.inventory,
    required this.snapshot,
  });

  /// 路由判定结果（冻结进快照的路线）。
  final ExportRouteDecision decision;

  /// 行记录（题目 ID → 冻结行；含答案/解析冻结值）。
  final Map<String, ExportQuestionRecord> recordsById;

  /// 盘点结果（guard 估算值 + 跳过清单）。
  final ExportInventory inventory;

  /// 快照（调用方负责 dispose）。
  final ExportSnapshot snapshot;
}

/// C 路线分页规划结果（规划 + 构建输入 + 转换期图块缺失标记）。
class _CPlanned {
  const _CPlanned({
    required this.plan,
    required this.questions,
    required this.extraFigureMissing,
  });

  final CPagePlan plan;
  final List<CBuildQuestion> questions;

  /// 转换期发现图块缺失的题（快照层未记的缺失，PARTIAL 判定用）。
  final Map<String, bool> extraFigureMissing;
}

/// C 路线一题的转换结果（块序列 + 降级标记）。
class _CConverted {
  const _CConverted({
    required this.layoutBlocks,
    required this.hasOriginalFormula,
    required this.hasShrunkFormula,
    required this.figureMissing,
  });

  final List<CLayoutBlock> layoutBlocks;
  final bool hasOriginalFormula;
  final bool hasShrunkFormula;
  final bool figureMissing;
}

/// Isolate 生成输出（字节 + 页数 + 逐题结果）。
class _IsolateOutput {
  const _IsolateOutput({
    required this.bytes,
    required this.totalPages,
    required this.questionPages,
    this.aQuestions,
    this.cQuestions,
  });

  final Uint8List bytes;
  final int totalPages;
  final List<ExportQuestionPage> questionPages;
  final List<AQuestionBuildResult>? aQuestions;
  final List<CQuestionBuildResult>? cQuestions;
}

/// A 路线逐题结果的轻量视图（只为复用 [ABuildResult.toIntegrityEntries]
/// 的条目转换，不重建整个 ABuildResult）。
class _ABuildResultView {
  const _ABuildResultView({required this.questions});

  final List<AQuestionBuildResult> questions;

  List<IntegrityEntry> toIntegrityEntries() => [
    for (final q in questions)
      IntegrityEntry(
        questionId: q.questionId,
        title: q.title,
        status: q.status,
        warnings: List.of(q.warnings),
        skipReason: q.skipReason,
      ),
  ];
}

// ------------------------------------------------------------------
// 生成 Isolate 入口（顶层函数；构建 + save 全在 Isolate 内）。
// ------------------------------------------------------------------

/// 生成 Isolate 入口：按 [message] 构建文档并 `save()`。
///
/// 消息为纯数据 Map（快照对象本身可跨 Isolate 发送，见 M1-E 探针）；
/// 成功回 `{'ok': true, ...}`，失败回 `{'ok': false, 'kind': ..., 'message': ...}`
/// （kind 供主 Isolate 还原异常类型；message 只含题号与原因，不含公式内容）。
///
/// 答案版（M2-1）两阶段构建：第一阶段建题目文档取题号（页脚分母暂为
/// 题目页数），由题号建答案区条目并单独排版计数答案区页数；第二阶段
/// 按已知总页数重建题目文档，再接上答案区 MultiPage（自新页起，
/// 页码全局连续，见 M2 探针结论），保存后数页校验总页数，对不上
/// 即抛错、不发布。答案区 widgets 每次构建都重新生成（pdf widget
/// 不跨文档复用）。练习版仍为单次构建（原行为，不变）。
void _pdfExportIsolateEntry(Map<String, Object?> message) async {
  final reply = message['reply'] as SendPort;
  try {
    final route = message['route'] as String;
    final fontBytes = message['fontBytes'] as Uint8List;
    final builder = PdfExportDocumentBuilder(
      font: PdfExportFont.fontFromBytes(fontBytes),
    );
    final metadata = PdfExportMetadata(
      title: message['title'] as String,
      author: message['author'] as String,
      creator: message['creator'] as String,
      producer: message['producer'] as String,
      subject: message['subject'] as String?,
      keywords: message['keywords'] as String?,
    );
    final headerInfo = PdfExportHeaderInfo(
      subjectName: message['subjectName'] as String,
      exportDateText: message['exportDateText'] as String,
    );
    final info = PdfExportInfo(
      filterText: message['filterText'] as String,
      questionCount: message['questionCount'] as int,
      exportDateText: message['exportDateText'] as String,
      sortText: message['sortText'] as String,
      routeText: message['routeText'] as String,
    );
    final variant = message['variant'] as String? ?? ExportVersion.practice.name;
    final isAnswer = variant == ExportVersion.answer.name;
    final answerSources = [
      for (final m in (message['answerSources'] as List? ?? const []))
        AnswerSourceData(
          questionId: (m as Map)['questionId'] as String,
          answer: m['answer'] as String?,
          explanation: m['explanation'] as String?,
          answerPendingRecheck: m['pendingRecheck'] as bool? ?? false,
        ),
    ];

    /// 建一次题目文档（两路线分支；[totalPagesOverride] 只用于答案版
    /// 第二阶段：题目区页脚分母须为总页数）。
    Future<_IsolateQuestionsDoc> buildQuestions({
      int? totalPagesOverride,
    }) async {
      if (route == ExportRoute.a.name) {
        final snapshot = message['snapshot'] as ExportSnapshot;
        final result = await AContentBuilder.buildDocument(
          snapshot: snapshot,
          documentBuilder: builder,
          metadata: metadata,
          headerInfo: headerInfo,
          info: info,
          excludeLowDpi: message['excludeLowDpi'] as bool,
          excludeBelowDpi: message['excludeBelowDpi'] as double,
          totalPagesOverride: totalPagesOverride,
          // M3-F：逐题来源行（主 Isolate 拼好传入；缺省 = 不印）。
          sourceTextById:
              (message['aSourceTexts'] as Map?)
                  ?.map((k, v) => MapEntry(k as String, v as String)) ??
              const <String, String>{},
        );
        return _IsolateQuestionsDoc(
          document: result.document,
          questionPageCount: result.plan.totalPages,
          questionPages: _aQuestionPages(result.plan, result.questions),
          numbersById: {
            for (final q in result.questions)
              if (q.questionNumber > 0) q.questionId: q.questionNumber,
          },
          aQuestions: result.questions,
        );
      }
      final plan = message['cPlan'] as CPagePlan;
      final questions = (message['cQuestions'] as List).cast<CBuildQuestion>();
      final tempDir = Directory(message['tempDirPath'] as String);
      final result = await CContentBuilder.buildDocument(
        plan: plan,
        tempDir: tempDir,
        questions: questions,
        documentBuilder: builder,
        metadata: metadata,
        headerInfo: headerInfo,
        info: info,
        totalPagesOverride: totalPagesOverride,
      );
      return _IsolateQuestionsDoc(
        document: result.document,
        questionPageCount: result.totalPages,
        questionPages: [
          for (final q in result.questions)
            <String, Object>{
              'questionId': q.questionId,
              'displayNumber': q.questionNumber,
              'pages': q.plannedPages,
            },
        ],
        numbersById: {
          for (final q in result.questions)
            q.questionId: q.questionNumber,
        },
        cQuestions: result.questions,
      );
    }

    if (!isAnswer) {
      // 练习版：单次构建（M1 原行为）。
      final built = await buildQuestions();
      // C-7：save() 必须 await；完成前不得发布文件。
      final bytes = await builder.savePdf(built.document);
      reply.send(<String, Object?>{
        'ok': true,
        'bytes': bytes,
        'totalPages': built.questionPageCount,
        'questionPages': built.questionPages,
        if (built.aQuestions != null) 'aQuestions': built.aQuestions,
        if (built.cQuestions != null) 'cQuestions': built.cQuestions,
      });
      return;
    }

    // 答案版第一阶段：建题目文档取题号 → 建答案区条目 → 单独排版计数。
    final first = await buildQuestions();
    final entries = buildAnswerEntries(
      displayNumbersById: first.numbersById,
      sources: answerSources,
    );
    if (entries.isEmpty) {
      throw StateError('答案版无可印题目对应的答案条目，本次导出已中止。');
    }
    final answerPages = await _countAnswerPages(
      builder: builder,
      metadata: metadata,
      headerInfo: headerInfo,
      entries: entries,
    );
    final totalPages = first.questionPageCount + answerPages;
    // 答案版第二阶段：按已知总页数重建题目文档，接上答案区 MultiPage。
    final second = await buildQuestions(totalPagesOverride: totalPages);
    if (!_sameQuestionPages(first.questionPages, second.questionPages)) {
      throw StateError('答案版两次构建题号不一致，本次导出已中止。');
    }
    second.document.addPage(
      builder.multiPage(
        children: answerSectionWidgets(entries, builder),
        plan: PdfPaginationPlan(totalPages: totalPages),
        headerInfo: headerInfo,
      ),
    );
    // C-7：save() 必须 await；完成前不得发布文件。
    final bytes = await builder.savePdf(second.document);
    final actualPages = countPdfPages(bytes);
    if (actualPages != totalPages) {
      throw StateError(
        '答案版页数校验失败：预期 $totalPages 页，'
        '实际 ${actualPages ?? '未知'} 页，本次导出已中止。',
      );
    }
    reply.send(<String, Object?>{
      'ok': true,
      'bytes': bytes,
      'totalPages': totalPages,
      'questionPages': second.questionPages,
      if (second.aQuestions != null) 'aQuestions': second.aQuestions,
      if (second.cQuestions != null) 'cQuestions': second.cQuestions,
    });
  } catch (e) {
    reply.send(<String, Object?>{
      'ok': false,
      'kind': _isolateErrorKind(e),
      'message': _isolateErrorMessage(e),
    });
  }
}

/// Isolate 内一次题目文档构建的结果（题目文档 + 题号表）。
class _IsolateQuestionsDoc {
  const _IsolateQuestionsDoc({
    required this.document,
    required this.questionPageCount,
    required this.questionPages,
    required this.numbersById,
    this.aQuestions,
    this.cQuestions,
  });

  /// 题目文档（未 save；答案版第二阶段还要接答案区 MultiPage）。
  final pw.Document document;

  /// 题目区页数（规划值；练习版即总页数）。
  final int questionPageCount;

  /// 每题题号与所在页（回主 Isolate 的 questionPages）。
  final List<Map<String, Object>> questionPages;

  /// 已印出题的题号表（题目 ID → 导出内题号；答案区条目用）。
  final Map<String, int> numbersById;

  /// A 路线逐题结果（C 路线为 null）。
  final List<AQuestionBuildResult>? aQuestions;

  /// C 路线逐题结果（A 路线为 null）。
  final List<CQuestionBuildResult>? cQuestions;
}

/// 答案区单独排版计数（一次性文档；只数页，不发布）。
///
/// 答案区与正式文档用同一套页面主题/页眉页脚、同一 widgets 构造；
/// 答案区自新页起、首末页均无导出信息区，排版结果与正式文档一致；
/// 正式文档保存后还要数页终态校验（见入口），双重保障。
Future<int> _countAnswerPages({
  required PdfExportDocumentBuilder builder,
  required PdfExportMetadata metadata,
  required PdfExportHeaderInfo headerInfo,
  required List<AnswerEntry> entries,
}) async {
  final probe = builder.createDocument(metadata: metadata);
  probe.addPage(
    builder.multiPage(
      children: answerSectionWidgets(entries, builder),
      plan: const PdfPaginationPlan(totalPages: 1),
      headerInfo: headerInfo,
    ),
  );
  final bytes = await builder.savePdf(probe);
  final pages = countPdfPages(bytes);
  if (pages == null) {
    throw StateError('答案区页数无法确定，本次导出已中止。');
  }
  return pages;
}

/// 两次构建的题号表是否一致（题号 + 所在页逐题比对）。
bool _sameQuestionPages(
  List<Map<String, Object>> a,
  List<Map<String, Object>> b,
) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i]['questionId'] != b[i]['questionId'] ||
        a[i]['displayNumber'] != b[i]['displayNumber']) {
      return false;
    }
    final pagesA = (a[i]['pages'] as List).join(',');
    final pagesB = (b[i]['pages'] as List).join(',');
    if (pagesA != pagesB) return false;
  }
  return true;
}

/// A 路线每题题号与所在页（按规划页 items 推导；段与占位块同题同号）。
List<Map<String, Object>> _aQuestionPages(
  AContentPlan plan,
  List<AQuestionBuildResult> questions,
) {
  final pagesById = <String, List<int>>{};
  final numbersById = <String, int>{};
  for (var pi = 0; pi < plan.pages.length; pi++) {
    for (final item in plan.pages[pi].items) {
      final String questionId;
      final int number;
      if (item is APlannedSegment) {
        questionId = item.questionId;
        number = item.questionNumber;
      } else if (item is APlannedBroken) {
        questionId = item.questionId;
        number = item.questionNumber;
      } else {
        continue;
      }
      (pagesById[questionId] ??= []).add(pi + 1);
      numbersById[questionId] = number;
    }
  }
  return [
    for (final q in questions)
      if (pagesById.containsKey(q.questionId))
        <String, Object>{
          'questionId': q.questionId,
          'displayNumber': numbersById[q.questionId] ?? q.questionNumber,
          'pages': (pagesById[q.questionId]!.toSet().toList()..sort()),
        },
  ];
}

/// Isolate 侧错误分类（供主 Isolate 还原异常类型）。
String _isolateErrorKind(Object e) {
  if (e is StateError && e.message == '本次没有可导出题目') {
    return 'noPrintable';
  }
  if (e is SnapshotIntegrityException) return 'integrity';
  if (e is SnapshotInfrastructureException) return 'infrastructure';
  if (e is ArgumentError) return 'argument';
  return 'other';
}

/// Isolate 侧错误信息（只含题号与原因；构建器报错不含公式内容）。
String _isolateErrorMessage(Object e) {
  if (e is StateError) return e.message;
  if (e is SnapshotIntegrityException) return e.message;
  if (e is SnapshotInfrastructureException) return e.message;
  if (e is ArgumentError) return e.message;
  return e.toString();
}
