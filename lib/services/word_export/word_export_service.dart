// 十六批 C（D-194/D-198/D-199/D-200/D-202/D-203）：Word 编排服务
// WordExportService（WORD-DESIGN.md §2/§5/§6）。
//
// 流程：路由判定 → 盘点 M1-0 → 快照 M1-1 → 生成（后台 Isolate 内，
// `DocxExporter().exportToBytes`）→ 完整性报告。输出“已验证的
// docx 字节 + 报告”，不含文件发布（发布属 `WordDeliveryService`）。
// 与 `PdfExportService` 同形态（`generateVersions` /
// `generateFromSnapshot`），但：
//  - 练习版与答案版是一份 `.docx` 内的两部分（D-197），不是两份文件，
//    故一次生成只产一份字节；[WordExportResult] 没有 totalPages 字段
//    （W-11：总页数生成时未知，完成界面不得编造页数）；
//  - 快照、盘点、可印判定、去重、guard、50 道上限全部复用 PDF 管线，
//    只调既有公共入口（`ExportSnapshot.fromSelection`、
//    `ContentGuard`、`runInventory`、`classifyC`/`classifyA`），
//    不复制快照/guard 实现；公式栅格化与 A 路线增强准备是编排胶水，
//    与 PDF `_rasterizeSnapshotFormulas` / `AContentBuilder._prepareEntry`
//    同口径（私有逻辑无法复用，按同一口径重写，见各方法注释）；
//  - 生成在后台 Isolate：`exportToBytes` 飞行中不可中断，允许当前导出
//    完成、丢弃结果、不再启动后续版本（与 PDF `save()` 飞行中模型同款）；
//  - 取消检查点：每题生成前检查一次；看门狗 60 s（`kWordGenerationWatchdogTimeout`，
//    与 PDF D-183 同值），超时 kill 子 Isolate + 抛错“生成超时，已中止，
//    未产生文件”；超时前未产生任何文件（落盘在回包之后才做）。
//  - LaTeX 源码绝不外露：本文件只见公式标识与文件引用，报错/日志只含
//    题号与原因，不含公式内容（C-11）。
//
// 快照归属：[generateVersions] 内部建快照，结束（成功/失败/取消）后
// 一律 dispose 快照（删整个临时目录）；[generateFromSnapshot] 不拥有
// 快照，调用方负责 dispose。
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:docx_creator/docx_creator.dart';

import '../../modules/ocr/formula_crop.dart';
import '../../modules/ocr/question_content.dart';
import '../../services/ocr_key_store.dart';
import '../pdf_export/answer_section.dart';
import '../pdf_export/content_guard.dart';
import '../pdf_export/export_integrity.dart';
import '../pdf_export/export_inventory.dart';
import '../pdf_export/export_question_record.dart';
import '../pdf_export/export_route.dart';
import '../pdf_export/export_snapshot.dart';
import '../pdf_export/export_versions.dart';
import '../pdf_export/formula_rasterizer.dart';
import '../pdf_export/image_enhancer.dart';
import '../pdf_export/pdf_document_builder.dart';
import '../pdf_export/pdf_export_service.dart'
    show
        ExportCancelledException,
        ExportGuardRejectException,
        ExportNoPrintableException,
        ExportCancellationToken;
import '../pdf_export/slice_snapshot.dart';
import '../pdf_export/slice_write_guard.dart';
import '../pdf_export/snapshot_exceptions.dart';
import 'word_content_builder.dart';
import 'word_formula_baseline.dart';

/// Word 生成 Isolate 看门狗超时（D-200：与 PDF D-183 的
/// `kPdfGenerationWatchdogTimeout` 同值 60 s）。
///
/// 主 Isolate 等生成 Isolate 回包的最长等待：超时则 kill 子 Isolate
/// 并明确报错“生成超时，已中止，未产生文件”。看门狗是兜底，不是规划期
/// 保护——Word 侧没有 PDF 式分页规划，看门狗只防导出器死循环。
/// 注意：超时前未产生任何文件（落盘在回包之后才做），故“未产生文件”
/// 为真，不是安慰文案。
const Duration kWordGenerationWatchdogTimeout = Duration(seconds: 60);

/// 编排服务的一次生成结果（已验证的 docx 字节 + 报告，不含文件发布）。
///
/// 没有 totalPages 字段（W-11；页数只有 Word 打开后才知道）。
class WordExportResult {
  const WordExportResult({
    required this.docxBytes,
    required this.report,
    required this.route,
    required this.estimatedGuard,
    required this.actualGuard,
    required this.guardDeviation,
    required this.imageCount,
    this.estimatedPageCount,
  });

  /// 已验证的 docx 字节（`exportToBytes` await 完成后的完整字节，
  /// 以 `PK\x03\x04` 开头）。
  final Uint8List docxBytes;

  /// 完整性报告（任务内数据，不存库；与 PDF 报告逐项相同，见
  /// WORD-DESIGN.md §5.4）。
  final IntegrityReport report;

  /// 本次路线（快照冻结值）。
  final ExportRoute route;

  /// 盘点 guard 估算值（标注“估算值”，D-181）。
  final ContentGuardResult estimatedGuard;

  /// 快照后实际值复核的 guard 结果（非估算值，D-181）。
  final ContentGuardResult actualGuard;

  /// 估算值与实际值的偏差记录（尤其 C 路线，记入验证记录）。
  final GuardDeviation guardDeviation;

  /// 本次嵌入的图片部件数（`word/media/*` 部件数，交付校验用）。
  final int imageCount;

  /// 估计总页数（十七批 A4，D-207：内容高度贪心分页模拟，见
  /// word_page_estimate.dart；只是估计，完成界面以「约 N 页
  /// （估计值）」展示。null 表示未知，不展示估计行）。
  final int? estimatedPageCount;
}

/// 编排服务：路由 → 盘点 → 快照 → 生成 → 报告。
class WordExportService {
  WordExportService({
    required this.source,
    Future<bool> Function()? hasApiKey,
    this.tempRoot,
    this.rasterizer,
    this.sourceTextFor,
    this.subjectName = '多学科',
    this.excludeLowDpi = false,
    this.excludeBelowDpi = kClarityWarnDpi,
  }) : _hasApiKey = hasApiKey ?? OcrKeyStore().hasApiKey;

  /// 数据源（生产用 [DriftExportQuestionSource]，测试用桩）。
  final ExportQuestionSource source;

  /// 读 OCR key 状态（只读有无，不读 key 本身；默认走 [OcrKeyStore]）。
  final Future<bool> Function() _hasApiKey;

  /// 快照临时目录根（仅测试用；默认系统临时目录）。
  final Directory? tempRoot;

  /// 公式栅格化器（调用方已 attach；C 路线有公式时用。null 时公式
  /// 走纯裁剪降级链：裁剪成功 → 原图（PARTIAL），裁剪失败 → 整题跳过；
  /// 与 `PdfExportService` 同口径）。
  final FormulaRasterizer? rasterizer;

  /// 每题来源行文字（学科 / 文件夹 / 考试名；不传则不印来源行，
  /// 与 `PdfExportService` 同款）。
  final String Function(ExportQuestionRecord record)? sourceTextFor;

  /// 页眉学科名（多学科时传“多学科”，不得取第一道题的学科作代表）。
  final String subjectName;

  /// 面板勾选“排除低于清晰度阈值的题”（默认 false，只警告、不排除）。
  final bool excludeLowDpi;

  /// 清晰度门禁排除阈值（默认 200 DPI）。
  final double excludeBelowDpi;

  /// 生成一次 Word 导出（练习版 + 答案版在同一份 `.docx` 内）。
  ///
  /// [ids] 为选中的原始题目 ID（filteredAll() 顺序，含排除题，≤ 50；
  /// 跳过题仍占名额，不得跳过后补入第 51 道，C-14）。
  /// [excluded] 为其中被排除的题（用户主动排除 / 清晰度门禁排除）。
  /// [circledCount] 为筛选范围题数（默认 = 本次选中题数）。
  /// [token] 为取消令牌（不传则用永不取消的令牌）。
  /// [versions] 为版本选择（默认只勾练习版；答案版勾选时答案区追加
  /// 在同一文件内，不另产文件；两版都不勾时阻断）。
  /// [onProgress] 为进度回调（可选；按题报数）。
  ///
  /// 快照由本方法内部创建并在结束时 dispose（成功/失败/取消都清理
  /// 整个临时目录）。盘点 guard 硬拒绝或零可印时不建快照，直接抛错。
  Future<WordExportResult> generateVersions({
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
      return await _generateFromSnapshotOwned(
        snapshot: frozen.snapshot,
        recordsById: frozen.recordsById,
        inventory: frozen.inventory,
        filterText: filterText,
        sortText: sortText,
        routeNotice: frozen.decision.notice,
        token: cancelToken,
        versions: versions,
        onProgress: onProgress,
      );
    } finally {
      // 任务结束（成功/失败/取消）清理整个临时目录。
      await frozen.snapshot.dispose();
    }
  }

  /// 用已有快照生成一次（与 `PdfExportService.generateFromSnapshot`
  /// 同形态；本方法不拥有快照，调用方负责 dispose）。
  Future<WordExportResult> generateFromSnapshot({
    required ExportSnapshot snapshot,
    Map<String, ExportQuestionRecord>? recordsById,
    ExportCancellationToken? token,
    ExportVersionSelection versions =
        const ExportVersionSelection.practiceOnly(),
    void Function(int done, int total, String label)? onProgress,
  }) async {
    if (!versions.hasAny) {
      throw ArgumentError('至少选择一个版本');
    }
    final cancelToken = token ?? ExportCancellationToken();
    // 服务入口复核快照题数 ≤ 50（第二道防线；快照工厂已校验）。
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
      versions: versions,
      onProgress: onProgress,
    );
  }

  Future<Map<String, ExportQuestionRecord>> _fetchRecords(
    ExportSnapshot snapshot,
    ExportCancellationToken token,
  ) async {
    final records = <String, ExportQuestionRecord>{};
    await token.checkpoint();
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

  /// 冻结一次导出（与 `PdfExportService._freezeExport` 同款前奏：
  /// 路由判定 → 读行 → 盘点 → 快照；只调既有公共入口，不复制快照实现）。
  ///
  /// guard 硬拒绝 / 零可印时不建快照，直接抛错（调用方不产生快照，
  /// 无需 dispose）。快照创建失败时 fromSelection 已清理临时目录。
  Future<_WordFrozenExport> _freezeExport({
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
    //    盘点与快照均按题目级跳过处理）。D-186：另记一份原始读行结果
    //    （含缺题 null），供 step 4 快照复用——单次读行，取消快照内部
    //    的二次 fetch；终态复核的第三次重读保留。
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
    return _WordFrozenExport(
      decision: decision,
      recordsById: recordsById,
      inventory: inventory,
      snapshot: snapshot,
    );
  }

  /// 快照后生成（generateVersions / generateFromSnapshot 共用；
  /// 不 dispose 快照）。
  Future<WordExportResult> _generateFromSnapshotOwned({
    required ExportSnapshot snapshot,
    required Map<String, ExportQuestionRecord> recordsById,
    required ExportInventory inventory,
    required String filterText,
    required String sortText,
    required String routeNotice,
    required ExportCancellationToken token,
    ExportVersionSelection versions =
        const ExportVersionSelection.practiceOnly(),
    void Function(int done, int total, String label)? onProgress,
  }) async {
    await token.checkpoint();
    // 服务入口复核快照题数 ≤ 50（第二道防线）。
    if (snapshot.questionCount > kExportMaxQuestions) {
      throw ArgumentError('单次最多导出 50 道题');
    }
    // 快照后变零衔接：快照后最终可印题数为 0，停止生成，不生成文件。
    if (snapshot.printableCount == 0) {
      throw ExportNoPrintableException(
        '本次没有可导出题目。${_snapshotSkipSummary(snapshot)}',
      );
    }
    // 取消时通知栅格化器（飞行中的 toImage() 完成后丢弃结果，
    // 不再启动后续渲染，与 PDF 同款）。
    if (rasterizer != null) {
      unawaited(
        token.whenCancelled.then((_) => rasterizer!.cancel()),
      );
    }
    // 答案版输入（冻结值，不重新查询题目；练习版不传）。
    final answerSources = versions.answer
        ? answerSourcesFromRecords(recordsById.values)
        : const <AnswerSourceData>[];
    final answersById = {
      for (final s in answerSources) s.questionId: s,
    };

    if (snapshot.route == ExportRoute.c) {
      final raster = await _rasterizeSnapshotFormulas(
        snapshot: snapshot,
        recordsById: recordsById,
        token: token,
        onProgress: onProgress,
      );
      // guard 实际值复核（D-181）：快照完成后、生成开始前，用实际
      // 栅格化后的像素数复核一次；超硬阈值 → 中止生成。
      final actualItems = await _actualGuardItemsC(
        snapshot: snapshot,
        verdicts: raster.verdicts,
        skippedQuestionIds: raster.skippedQuestionIds,
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
      onProgress?.call(
        snapshot.selectedCount,
        snapshot.selectedCount,
        '正在生成 Word…',
      );
      await token.checkpoint();
      final content = buildWordContent(
        snapshot: snapshot,
        answersById: answersById,
        versions: versions,
        subjectName: subjectName,
        recordsById: recordsById,
        sourceTextFor: sourceTextFor,
        formulaVerdicts: raster.verdicts,
      );
      final bytes = await _exportInIsolate(content.document.build(), token);
      // 十八批 P1（D-216）：C 路线行内公式基线对齐——导出后再注入
      // run 级 w:position（见 word_formula_baseline.dart；无下移
      // 项时原样返回，不碰字节；注入结构对不上时抛错，按生成失败处理）。
      final shiftedBytes = applyWordFormulaBaselineShifts(
        bytes,
        content.drawingPositionHalfPoints,
      );
      return _finishC(
        snapshot: snapshot,
        recordsById: recordsById,
        inventory: inventory,
        actualGuard: actualGuard,
        content: content,
        formulaSkipped: raster.skippedQuestionIds,
        bytes: shiftedBytes,
      );
    }

    // A 路线：逐题增强准备（主 Isolate，每题前检查点；与 PDF
    // `AContentBuilder._prepareEntry` 同口径，见 [_prepareAEntry]）。
    final prepared = <String, WordAPreparedQuestion>{};
    for (var i = 0; i < snapshot.entries.length; i++) {
      final entry = snapshot.entries[i];
      await token.checkpoint();
      prepared[entry.questionId] = await _prepareAEntry(
        entry: entry,
        index: i,
        snapshot: snapshot,
      );
      onProgress?.call(i + 1, snapshot.selectedCount, '正在准备题目…');
    }
    // guard 实际值复核（与 PDF A 路线同口径：上限后切片像素数）。
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
    // 快照后变零衔接（A 路线门禁级）：可印题全被门禁跳过 → 停止生成。
    final printableAfterPrepare =
        snapshot.entries
            .where(
              (e) =>
                  (e.outcome == SnapshotOutcome.ready &&
                      !(prepared[e.questionId]?.isSkipped ?? true)) ||
                  e.outcome == SnapshotOutcome.broken,
            )
            .length;
    if (printableAfterPrepare == 0) {
      throw ExportNoPrintableException(
        '本次没有可导出题目。${_snapshotSkipSummary(snapshot)}',
      );
    }
    onProgress?.call(
      snapshot.selectedCount,
      snapshot.selectedCount,
      '正在生成 Word…',
    );
    await token.checkpoint();
    final content = buildWordContent(
      snapshot: snapshot,
      answersById: answersById,
      versions: versions,
      subjectName: subjectName,
      recordsById: recordsById,
      sourceTextFor: sourceTextFor,
      aPrepared: prepared,
    );
    final bytes = await _exportInIsolate(content.document.build(), token);
    return _finishA(
      snapshot: snapshot,
      recordsById: recordsById,
      inventory: inventory,
      actualGuard: actualGuardA,
      content: content,
      prepared: prepared,
      bytes: bytes,
    );
  }

  // ------------------------------------------------------------------
  // C 路线：公式栅格化（主 Isolate；与 PdfExportService 同口径）。
  // ------------------------------------------------------------------

  /// 逐题栅格化快照内全部公式（主 Isolate；每题前检查点）。
  ///
  /// 返回每题的裁决与因公式失败整题跳过的题 ID。任一公式渲染失败
  /// 且原图裁剪亦失败 → 整题 SKIPPED（其余公式/正文/图块/答案再完整
  /// 也不印）；任一公式为原图 → 该题 PARTIAL。
  Future<_WordCRasterWork> _rasterizeSnapshotFormulas({
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
      // 每题生成前检查点（让出执行权再检查标志）。
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
    return _WordCRasterWork(verdicts: verdicts, skippedQuestionIds: skipped);
  }

  /// 一题多公式栅格化 + 降级链（与 `PdfExportService` 同口径）。
  ///
  /// 公式按块序列文档顺序编号（`q<题序>-f<序号>`）；原图裁剪的
  /// formulaIndex 取同一序号（cropFormulaImageBytes 按 ocrRaw 的
  /// 公式框列表取框，与块序列顺序一致是本包的前提假设）。
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

  /// 无栅格化器时的纯裁剪降级链（与 `PdfExportService` 同口径）：
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

  /// C 路线 guard 实际值复核的输入（D-181/C-13，与
  /// `PdfExportService._actualGuardItemsC` 同口径）：公式位图
  /// （栅格化后实际像素数）+ 图块裁剪（300 DPI 限制后像素数）。
  /// 不印的题不计入。
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

  /// 图块显示尺寸（pt）：300 DPI 自然尺寸，上限内容区宽（与
  /// `PdfExportService._figureDisplaySize` 同口径）。
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

  // ------------------------------------------------------------------
  // A 路线：逐题增强准备（主 Isolate；与 AContentBuilder._prepareEntry
  // 同口径，Word 侧不写 enhanced/ 临时文件——增强后字节直接嵌进文档）。
  // ------------------------------------------------------------------

  /// 准备一道 A 路线题：验哈希 → 增强 → 门禁判定。
  ///
  /// 失败分类（D-179）：源缺失/损坏/无法解码 → 题目级 BROKEN；
  /// 快照副本哈希不一致 → 整单中止（抛 [SnapshotIntegrityException]）。
  Future<WordAPreparedQuestion> _prepareAEntry({
    required SnapshotQuestionEntry entry,
    required int index,
    required ExportSnapshot snapshot,
  }) async {
    if (entry.outcome == SnapshotOutcome.skipped) {
      return WordAPreparedQuestion(
        isSkipped: true,
        skipReason: entry.skipReason,
        warnings: List.of(entry.warnings),
      );
    }
    if (entry.outcome == SnapshotOutcome.broken ||
        entry.sliceCopy == null) {
      return WordAPreparedQuestion(
        isBroken: true,
        brokenReason: entry.warnings.isNotEmpty
            ? entry.warnings.first
            : '源切片缺失',
        warnings: List.of(entry.warnings),
      );
    }
    final copy = entry.sliceCopy!;
    final tempFile = File(
      '${snapshot.tempDir.path}${Platform.pathSeparator}'
      '${copy.tempRelativePath}',
    );
    // 验哈希：生成只读临时副本，读取时核对（M1 §6）。
    final hashOk = await SliceSnapshot.verifyTempCopy(
      tempFile: tempFile,
      expectedHash: copy.sourceHash,
    );
    if (!hashOk) {
      throw SnapshotIntegrityException(
        '临时副本与源切片不一致，本次导出中止，请重试。',
      );
    }
    late final Uint8List bytes;
    try {
      bytes = await tempFile.readAsBytes();
    } catch (_) {
      throw SnapshotIntegrityException(
        '读取快照临时副本失败，本次导出中止。',
      );
    }
    // 增强（解码 → 下采样到上限 → 增强 → 编码；失败回退，见 D-182）。
    final enhance = ImageEnhancer.enhanceSlice(
      sliceBytes: bytes,
      params: const ImageEnhanceParams.defaults(),
    );
    if (enhance.isUndecodable) {
      return WordAPreparedQuestion(
        isBroken: true,
        brokenReason: '切片无法解码',
        warnings: ['切片无法解码'],
        effectiveDpi: 0,
        lowDpi: true,
      );
    }
    final dpi = enhance.effectiveDpi;
    // 门禁：增强成功但门禁不通过 → 跳过（不回退，D-167 边界）。
    if (ImageEnhancer.shouldSkipForClarity(
      effectiveDpi: dpi,
      excludeLowDpi: excludeLowDpi,
      excludeBelowDpi: excludeBelowDpi,
    )) {
      return WordAPreparedQuestion(
        isSkipped: true,
        skipReason:
            '清晰度低于阈值（有效分辨率约 ${dpi.toStringAsFixed(0)} DPI）',
        warnings: [
          '清晰度低于阈值（有效分辨率约 ${dpi.toStringAsFixed(0)} DPI）',
        ],
        effectiveDpi: dpi,
        lowDpi: true,
      );
    }
    final warnings = <String>[];
    if (enhance.isFallback) {
      warnings.add('增强失败，已用原图');
    }
    if (enhance.clarity == ClarityLevel.severe) {
      warnings.add(
        '图片清晰度明显偏低（有效分辨率约 ${dpi.toStringAsFixed(0)} DPI）',
      );
    } else if (enhance.clarity == ClarityLevel.warning) {
      warnings.add(
        '图片清晰度偏低（有效分辨率约 ${dpi.toStringAsFixed(0)} DPI）',
      );
    }
    return WordAPreparedQuestion(
      enhancedBytes: enhance.bytes,
      cappedWidthPx: enhance.cappedWidthPx,
      cappedHeightPx: enhance.cappedHeightPx,
      enhanceFallback: enhance.isFallback,
      lowDpi: enhance.clarity != ClarityLevel.ok,
      effectiveDpi: dpi,
      warnings: warnings,
    );
  }

  // ------------------------------------------------------------------
  // 生成 Isolate（exportToBytes）+ 看门狗。
  // ------------------------------------------------------------------

  /// 在后台 Isolate 内跑 `DocxExporter().exportToBytes`（D-200）。
  ///
  /// 取消时 kill Isolate（`Isolate.spawn` + 端口，`Isolate.run` 无法
  /// 强制终止），编排层清理整个临时目录，不留半截 docx。
  /// `exportToBytes` 飞行中不可中断：允许当前导出完成、丢弃结果、
  /// 不再启动后续版本（与 PDF `save()` 飞行中模型同款）。
  Future<Uint8List> _exportInIsolate(
    DocxBuiltDocument doc,
    ExportCancellationToken token,
  ) async {
    final receivePort = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _wordExportIsolateEntry,
        <String, Object?>{'reply': receivePort.sendPort, 'doc': doc},
      );
      final replyFuture = receivePort.first.then(
        (m) => m as Map<String, Object?>,
      );
      // D-200：看门狗——回包等待加 60 s 超时（正常生成远低于此）。
      // 超时即 kill 子 Isolate 并明确报错，不静默挂起、不留半截文件。
      final reply = await Future.any([
        replyFuture,
        token.whenCancelled.then(
          (_) => throw const ExportCancelledException(),
        ),
      ]).timeout(
        kWordGenerationWatchdogTimeout,
        onTimeout: () =>
            throw TimeoutException('Word 生成超时，已中止，未产生文件'),
      );
      if (reply['ok'] != true) {
        throw StateError(reply['message'] as String? ?? 'Word 生成失败');
      }
      final bytes = reply['bytes'] as Uint8List;
      if (bytes.isEmpty || !_startsWithDocxMagic(bytes)) {
        throw StateError('生成的 Word 文件无效（文件为空或内容不是 Word 文档），请重试。');
      }
      return bytes;
    } on TimeoutException {
      // 看门狗超时：kill 子 Isolate，明确报错；落盘在回包之后才做，
      // 超时前未产生任何文件。
      isolate?.kill(priority: Isolate.immediate);
      throw StateError('Word 生成超时，已中止，未产生文件');
    } on ExportCancelledException {
      isolate?.kill(priority: Isolate.immediate);
      rethrow;
    } finally {
      receivePort.close();
    }
  }

  bool _startsWithDocxMagic(Uint8List bytes) {
    if (bytes.length < 4) return false;
    return bytes[0] == 0x50 && // P
        bytes[1] == 0x4B && // K
        bytes[2] == 0x03 &&
        bytes[3] == 0x04;
  }

  // ------------------------------------------------------------------
  // 收尾：完整性报告（C-14 计数守恒核对）。
  // ------------------------------------------------------------------

  WordExportResult _finishC({
    required ExportSnapshot snapshot,
    required Map<String, ExportQuestionRecord> recordsById,
    required ExportInventory inventory,
    required ContentGuardResult actualGuard,
    required WordContentResult content,
    required Set<String> formulaSkipped,
    required Uint8List bytes,
  }) {
    final byId = {
      for (final q in content.questions) q.questionId: q,
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
      final built = byId[entry.questionId];
      final ocr = entry.ocrContent;
      if (built == null || ocr == null) {
        // 防御性分支（不应发生：ready 题必有构建结果与 OCR 内容）：
        // 按跳过处理，不抛错、不丢计数。
        entries.add(
          IntegrityEntry(
            questionId: entry.questionId,
            title: entry.title,
            status: IntegrityStatus.skipped,
            warnings: List.of(entry.warnings),
            skipReason: '无 OCR 结果',
          ),
        );
        continue;
      }
      entries.add(
        IntegrityEntry(
          questionId: entry.questionId,
          title: entry.title,
          status: classifyC(
            printable: true,
            formulaOriginal: built.formulaOriginal,
            figureMissing:
                ocr.hasFigureMissing || built.figureMissing,
            optionUncertain: built.optionUncertain,
            contentParseFallback: built.contentParseFallback,
          ),
          warnings: List.of(built.warnings),
        ),
      );
    }
    final report = _buildReport(
      snapshot: snapshot,
      recordsById: recordsById,
      entries: entries,
    );
    return WordExportResult(
      docxBytes: bytes,
      report: report,
      route: ExportRoute.c,
      estimatedGuard: inventory.guard,
      actualGuard: actualGuard,
      guardDeviation: ContentGuard.compareEstimateVsActual(
        estimatedMpx: inventory.guard.totalRasterMpx,
        actualMpx: actualGuard.totalRasterMpx,
      ),
      imageCount: content.imageCount,
      estimatedPageCount: content.estimatedPageCount,
    );
  }

  WordExportResult _finishA({
    required ExportSnapshot snapshot,
    required Map<String, ExportQuestionRecord> recordsById,
    required ExportInventory inventory,
    required ContentGuardResult actualGuard,
    required WordContentResult content,
    required Map<String, WordAPreparedQuestion> prepared,
    required Uint8List bytes,
  }) {
    final byId = {
      for (final q in content.questions) q.questionId: q,
    };
    final entries = <IntegrityEntry>[];
    for (final entry in snapshot.entries) {
      if (entry.outcome == SnapshotOutcome.skipped) {
        entries.add(
          IntegrityEntry(
            questionId: entry.questionId,
            title: entry.title,
            status: IntegrityStatus.skipped,
            warnings: List.of(entry.warnings),
            skipReason: entry.skipReason,
          ),
        );
        continue;
      }
      final prep = prepared[entry.questionId];
      if (prep != null && prep.isSkipped) {
        entries.add(
          IntegrityEntry(
            questionId: entry.questionId,
            title: entry.title,
            status: IntegrityStatus.skipped,
            warnings: List.of(prep.warnings),
            skipReason: prep.skipReason,
          ),
        );
        continue;
      }
      final built = byId[entry.questionId];
      if (built == null) {
        entries.add(
          IntegrityEntry(
            questionId: entry.questionId,
            title: entry.title,
            status: IntegrityStatus.skipped,
            warnings: List.of(entry.warnings),
            skipReason: '未印出',
          ),
        );
        continue;
      }
      entries.add(
        IntegrityEntry(
          questionId: entry.questionId,
          title: entry.title,
          status: classifyA(
            sliceOk: !built.isBroken,
            enhanceFailedFallback: built.enhanceFallback,
            lowDpi: built.lowDpi,
          ),
          warnings: List.of(built.warnings),
        ),
      );
    }
    final report = _buildReport(
      snapshot: snapshot,
      recordsById: recordsById,
      entries: entries,
    );
    return WordExportResult(
      docxBytes: bytes,
      report: report,
      route: ExportRoute.a,
      estimatedGuard: inventory.guard,
      actualGuard: actualGuard,
      guardDeviation: ContentGuard.compareEstimateVsActual(
        estimatedMpx: inventory.guard.totalRasterMpx,
        actualMpx: actualGuard.totalRasterMpx,
      ),
      imageCount: content.imageCount,
      estimatedPageCount: content.estimatedPageCount,
    );
  }

  /// 完整性报告组装（与 `PdfExportService._buildReport` 同口径：
  /// 答案/解析已录入数按冻结记录分别判空；计数守恒核对，对不上即
  /// 整单失败，不返回半截结果）。
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
class _WordCRasterWork {
  const _WordCRasterWork({
    required this.verdicts,
    required this.skippedQuestionIds,
  });

  /// 每题裁决（questionId → 裁决）。
  final Map<String, QuestionFormulaVerdict> verdicts;

  /// 因公式失败整题跳过的题 ID。
  final Set<String> skippedQuestionIds;
}

/// 一次冻结的导出（_freezeExport 的产物：路由判定 + 行记录 +
/// 盘点 + 快照；generateVersions 共用，与 `PdfExportService`
/// 的 `_FrozenExport` 同款）。
class _WordFrozenExport {
  const _WordFrozenExport({
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

/// Isolate 入口：在子 Isolate 内跑 `DocxExporter().exportToBytes`。
///
/// 只传 kind + 文案回主 Isolate（不含公式内容）。`DocxBuiltDocument`
/// 由主 Isolate 传进（探针已验证可跨 Isolate 传递，见
/// `test/b16_word_isolate_probe_test.dart`——已删，结论见
/// WORD-IMPL-SUMMARY.md）。
Future<void> _wordExportIsolateEntry(Map<String, Object?> message) async {
  final reply = message['reply'] as SendPort;
  try {
    final doc = message['doc'] as DocxBuiltDocument;
    final bytes = await DocxExporter().exportToBytes(doc);
    reply.send(<String, Object?>{'ok': true, 'bytes': bytes});
  } catch (e) {
    reply.send(<String, Object?>{'ok': false, 'message': 'Word 生成失败，请重试。'});
  }
}
