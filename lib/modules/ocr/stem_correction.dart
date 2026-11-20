// 十三批 M5：纠错保存规则（纯函数 + 一个入队 helper，整理页与详情页共用）。
//
// 保存规则（M3 §4 定稿，M5 的纠错保存必须遵守，否则 worker 的
// “领取后内容是否变过”校验失效）：
// - 人工编辑保存：ocr_stem 写新题干、ocr_split_status 写“人工调整”
//   （[StemSplitStatus.manuallyAdjusted]）、ocr_manual_edited=1、
//   contentVersion +1、raw 里的候选状态清掉（[clearOcrCandidateFlag]）。
// - 接受候选（十三批 P1-1，GPT §2.3；十三批 P1 第二轮原子化）：见
//   [acceptCandidateStem]——重读题目行、候选仍 pending 确认、当前
//   slice_path 身份确认、切片 hash 核验、条件写入题干/切分状态/
//   候选状态/版本号，全在同一个 Drift 事务里；hash 不符时标 stale
//   的写入同样是条件更新（只当库里仍是验过的那个 pending 包时才写，
//   迟到的新候选绝不被误标）。接受成功后候选状态写 accepted，题干写进
//   ocr_stem、切分状态写回 splitStem 的结果、ocr_manual_edited 保持
//   原值、contentVersion +1。接受时不要求 content_version 仍等于
//   OCR 领取时的版本（用户人工改过题干但切片没变时，正是需要比较并
//   主动接受的情形）。接受的题干一律从 ocr_raw 包里取，不用调用方传的
//   预览字符串——调用方传什么都不影响最终写入内容。接受在函数内直接
//   落库并返回 AcceptedCandidate（已保存的题 + 未匹配上的手动图块 ID，
//   Win11 反馈尾巴 1），调用方不再另行 repo.save。
// - 忽略候选：只把 raw 里的候选状态写 ignored，contentVersion +1；
//   已接受/已忽略/stale/无候选时原样返回，不动版本（重复忽略是空操作）。
// - 其他保存（整理表单、详情编辑改答案/文件夹等）不碰 content_version——
//   它只跟踪 OCR 内容，不跟踪题目全部字段。
//
// 跨模块规则（GPT 评审末节，M3/M5 共守）：原图永远是最终依据；OCR 自动
// 结果不能覆盖人工结果（worker 侧只写候选，见 ocr_queue.dart）；
// 没 key、没网不影响题目的保存、查看、复习、编辑（本文件的保存
// 全是本地写库，不调网络、不读 key）。

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../data/data_change_events.dart';
import '../../data/database.dart';
import '../../data/drift/quiz_database.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../services/glm_ocr_client.dart';
import '../../services/import_guess.dart';
import '../../services/ocr_queue.dart';
import '../../services/stem_splitter.dart';
import 'figure_files.dart';
import 'ocr_figures.dart';
import 'question_classifier.dart';

/// 接受候选被拒绝：[reason] 是机器码（调用方按它给用户明确原因），
/// [message] 是给用户看的中文原因。
/// - `question_deleted`：题目已被删；
/// - `no_candidate`：没有待处理的识别结果（raw 缺失或状态为 none）；
/// - `not_pending`：候选已被接受/忽略/标 stale，不能重复接受；
/// - `hash_mismatch`：候选来自旧切片（已重新框选），已标 stale；
/// - `slice_missing`：切片文件不存在，无法核对候选来源。
class CandidateRejection implements Exception {
  CandidateRejection(this.reason, this.message);

  final String reason;
  final String message;

  @override
  String toString() => 'CandidateRejection($reason): $message';
}

/// 接受候选的返回值（Win11 反馈尾巴 1）：已保存的题 + 接受时没匹配
/// 上的手动图块 ID（[mergeManualFigures] 的 unmatchedManualIds，
/// 是加 `-manual` 后缀后的新 ID，已保留在图块序列末尾）。
/// 调用方（Notifier）把 [unmatchedManualIds] 经
/// [AcceptCandidateOutcome] 带到页面提示用户，不静默丢图。
class AcceptedCandidate {
  const AcceptedCandidate({
    required this.question,
    this.unmatchedManualIds = const [],
  });

  final Question question;
  final List<String> unmatchedManualIds;
}

/// Notifier 接受候选的结果（Win11 反馈尾巴 1）：成功时 [reason] 为
/// null，[unmatchedManualIds] 是接受时没匹配上的手动图块 ID（已保留
/// 在末尾，页面据此提示用户一次）；失败时 [reason] 是
/// [CandidateRejection.reason] 或 'save_failed' / 'no_question'，
/// [unmatchedManualIds] 为空。
class AcceptCandidateOutcome {
  const AcceptCandidateOutcome({
    required this.reason,
    this.unmatchedManualIds = const [],
  });

  final String? reason;
  final List<String> unmatchedManualIds;

  bool get accepted => reason == null;
}

/// 人工编辑保存：把编辑器拼出的新题干写进题（见文件头规则）。
/// [newStem] 是编辑器按块拼回的 Markdown 题干（公式仍以 `$...$`
/// 形式存内部数据，不外露）。
Question applyManualStemEdit(Question question, String newStem) {
  return question.copyWith(
    ocrStem: newStem,
    ocrSplitStatus: StemSplitStatus.manuallyAdjusted.label,
    ocrManualEdited: true,
    contentVersion: question.contentVersion + 1,
    ocrRaw: clearOcrCandidateFlag(question.ocrRaw),
  );
}

/// 接受候选（十三批 P1-1，GPT §2.3；十三批 P1 第二轮原子化）：
/// 重读题目行、候选仍 pending 确认、当前 slice_path 身份确认、切片
/// hash 核验、条件写入题干/切分状态/候选状态/版本号，全在同一个
/// Drift 事务里（照抄 [OcrWorker.applyClaimedResult] 的模式）——
/// 事务内重读到的行就是写入时比较的行，重框并发改动不可能插进
/// “校验通过 → 写入”之间。
///
/// 1. 题目仍存在；
/// 2. 候选的 input_hash 与当前切片 hash 一致（inputHash 为 null 的
///    是十三批前的遗留包，无基线可比，跳过 hash 核对——十三批未推送，
///    新包恒有 hash）；
/// 3. 候选仍处于 pending 状态（已接受/已忽略/stale 都拒绝）。
///
/// 任一不符抛 [CandidateRejection]（带明确原因）；hash 不一致时先把
/// 库里候选标 stale 再拒绝——标 stale 也是同一事务内的条件更新，
/// 只当库里仍是验过的那个 pending 包时才写（行数 1 才算标上了），
/// 迟到的新候选已写回时行数为 0，绝不误标新候选；标完事务正常提交，
/// 事务完成后再抛拒绝。成功时直接在事务内落库并返回 [AcceptedCandidate]
///（已保存的题 + 未匹配上的手动图块 ID，见 [mergeManualFigures]；
/// 调用方不再另行 repo.save）：
/// 候选题干从 raw 包里取
/// （[pendingCandidateStem] 的同款推导），ocr_manual_edited 保持
/// 原值，contentVersion +1，raw 候选状态写 accepted。
/// 条件更新行数不是 1 时抛 [StateError] 回滚整笔（调用方按
/// save_failed 处理）。写库成功后发一次变更事件（与旧流程里
/// repo.save 发的事件同口径：写后发，见 data_change_events.dart）。
Future<AcceptedCandidate> acceptCandidateStem(
  QuestionRepository repo,
  Question question,
) async {
  final d = await repo.db.db;
  Question? accepted;
  CandidateRejection? rejection;
  var wrote = false;
  // Win11 反馈尾巴 1：接受时没匹配上的手动图块 ID（已保留在末尾），
  // 事务提交后随返回值带给调用方提示用户；拒绝路径下为空。
  var unmatchedManualIds = const <String>[];
  // 十四批 M2：接受候选时新图块随候选包一起写回（同一 customUpdate 写
  // ocr_stem + ocr_split_status + ocr_figures + ocr_raw（accepted）+
  // content_version+1）。裁图在事务外先做（写文件协议），事务失败
  // 则删刚写的图块文件；拒绝/回滚时同样清理，不留无效引用。
  FigureWriteResult? pendingFigureWrite;
  var figuresCommitted = false;
  try {
    await d.transaction(() async {
    final row = await (d.select(
      d.questions,
    )..where((t) => t.id.equals(question.id))).getSingleOrNull();
    if (row == null) {
      rejection = CandidateRejection('question_deleted', '题目已被删除，候选无法接受');
      return;
    }
    final fresh = _questionFromRow(row);
    final pendingRaw = row.ocrRaw;
    if (pendingRaw == null) {
      rejection = CandidateRejection('no_candidate', '没有待处理的识别结果');
      return;
    }
    final raw = GlmOcrRawData.tryParse(pendingRaw);
    if (raw == null || raw.candidateStatus == OcrCandidateStatus.none) {
      rejection = CandidateRejection('no_candidate', '没有待处理的识别结果');
      return;
    }
    if (raw.candidateStatus != OcrCandidateStatus.pending) {
      rejection = CandidateRejection(
        'not_pending',
        '这份识别结果已经处理过（${raw.candidateStatus.name}），不能重复接受',
      );
      return;
    }
    // inputHash 为 null 的是十三批前的遗留包，无基线可比，跳过 hash
    // 核对（也不要求切片文件存在）；新包恒有 hash，必须核对。
    // hash 在事务内算（切片是不可变版本文件，同一路径内容不会变；
    // 路径身份以事务内读到的行为准）。
    if (raw.inputHash != null) {
      final currentHash = await _currentSliceHashForPath(row.slicePath);
      if (currentHash == null) {
        rejection = CandidateRejection(
          'slice_missing',
          '切片文件不存在，无法核对候选来源',
        );
        return;
      }
      if (raw.inputHash != currentHash) {
        // 候选来自另一张切片：条件标 stale 后拒绝，绝不能作为当前
        // 切片接受。WHERE 绑死验过的那个 pending 包原串：迟到的新
        // 候选已写回时行数为 0，不写、不误标，拒绝照样抛。
        final staleJson = raw
            .withCandidateStatus(OcrCandidateStatus.stale)
            .toJsonString();
        final marked = await d.customUpdate(
          'UPDATE questions SET ocr_raw = ?, content_version = content_version + 1 WHERE id = ? AND ocr_raw = ?',
          variables: [
            Variable<String>(staleJson),
            Variable<String>(question.id),
            Variable<String>(pendingRaw),
          ],
          updates: {d.questions},
        );
        if (marked == 1) wrote = true;
        rejection = CandidateRejection(
          'hash_mismatch',
          '识别结果来自旧切片（已重新框选），已标记为过期，不能接受',
        );
        return;
      }
    }
    final split = splitStem(raw.mdResults);
    final acceptedJson = raw
        .withCandidateStatus(OcrCandidateStatus.accepted)
        .toJsonString();
    // 十四批 M1：与题干写回同一事务内做题型分类（content_version +1
    // 已含在本次更新里，不另计）。来源守门与 worker 自动应用同款：
    // 'manual' 的字段不写，两字段互不影响。
    final classification = classifyQuestion(raw: raw, split: split);
    final plan = planClassificationWrite(
      currentTypeSource: row.questionTypeSource,
      currentTagsSource: row.questionBackgroundTagsSource,
      classification: classification,
    );
    // 十四批 M2：新图块只随候选包存在——从接受的这份 raw 派生（用 raw
    // 包里的真实转换元数据；元数据缺失时安全弃用图块，不猜坐标）。
    // 内容没变时沿用旧图块文件，不重写、不 churn；图块写失败时降级
    // 为 []（不阻断候选接受，题干仍写回）。
    final derivedFigures = buildOcrFigures(
      questionId: question.id,
      raw: raw,
      transform: raw.transform,
      slicePath: row.slicePath ?? '',
      inputHash: raw.inputHash,
    );
    final oldFigures = parseOcrFigures(row.ocrFigures);
    // Win11 反馈包 3：重识别产生新图块 ID 时，用 mergeManualFigures
    // 保留已有 manual 图块（按裁图区域匹配；匹配不上的保留在末尾并
    // 上报，绝不静默丢弃——见 ocr_figures.dart）。
    final merged = mergeManualFigures(
      oldFigures: oldFigures,
      newFigures: derivedFigures,
    );
    final mergedFigures = merged.figures;
    unmatchedManualIds = merged.unmatchedManualIds;
    if (merged.unmatchedManualIds.isNotEmpty) {
      debugPrint(
        'Win11 包 3：接受候选时 ${merged.unmatchedManualIds.length} 张'
        '手动排过的图块在新识别里没找到，已保留在末尾：'
        '${merged.unmatchedManualIds.join(', ')}（题 ${question.id}）',
      );
    }
    List<OcrFigure> figuresToStore;
    if (sameFiguresIgnoringCrop(oldFigures, mergedFigures)) {
      figuresToStore = oldFigures;
    } else if (mergedFigures.isEmpty) {
      figuresToStore = const [];
    } else {
      // 已带裁图文件的图块（保留下来的 manual 图块）直接复用；
      // 只有 cropPath 为空的才需要新裁图——writeFigureFiles 会给
      // 每个传入图块重新裁图并分配新路径，旧裁图传进去会被重裁、
      // 旧文件变孤儿。
      final toWrite = mergedFigures
          .where((f) => f.cropPath.isEmpty)
          .toList();
      // 裁图失败时的底线：只丢弃本次没裁出来的新图块，已带裁图文件
      // 的 manual 图块保留——裁图失败绝不能连带丢掉用户手动排过的图块。
      figuresToStore = mergedFigures
          .where((f) => f.cropPath.isNotEmpty)
          .toList();
      if (toWrite.isNotEmpty) {
        final sliceAbs = AppDatabase.resolveDataPath(row.slicePath ?? '');
        if (sliceAbs != null) {
          try {
            final sliceBytes = await File(sliceAbs).readAsBytes();
            final figureWrite = await writeFigureFiles(
              dataDir: AppDatabase.dataDirectoryPath(),
              questionId: question.id,
              sliceBytes: sliceBytes,
              figures: toWrite,
            );
            pendingFigureWrite = figureWrite;
            final writtenById = {
              for (final f in figureWrite.figures) f.id: f,
            };
            figuresToStore = [
              for (final f in mergedFigures) writtenById[f.id] ?? f,
            ];
          } on FigureWriteException {
            // 保留上面算好的已带裁图子集，不动。
          }
        }
      }
    }
    final setParts = <String>[
      'ocr_stem = ?',
      'ocr_split_status = ?',
      'ocr_raw = ?',
      'ocr_figures = ?',
    ];
    final variables = <Variable<Object>>[
      Variable<String>(split.stemText),
      Variable<String>(split.status.label),
      Variable<String>(acceptedJson),
      Variable<String>(encodeOcrFigures(figuresToStore)),
    ];
    if (plan.writeType) {
      setParts.add('question_type = ?');
      variables.add(Variable<String>(plan.questionType));
      setParts.add('question_type_source = ?');
      variables.add(Variable<String>(plan.questionTypeSource));
    }
    if (plan.writeTags) {
      setParts.add('question_background_tags = ?');
      variables.add(Variable<String>(plan.backgroundTags));
      setParts.add('question_background_tags_source = ?');
      variables.add(Variable<String>(plan.backgroundTagsSource));
    }
    setParts.add('content_version = content_version + 1');
    variables.addAll([
      Variable<String>(question.id),
      Variable<String>(pendingRaw),
    ]);
    final rows = await d.customUpdate(
      'UPDATE questions SET ${setParts.join(', ')} WHERE id = ? AND ocr_raw = ?',
      variables: variables,
      updates: {d.questions},
    );
    if (rows != 1) {
      // 事务内读到的 pending 包在写入前被并发改动：回滚整笔，
      // 调用方按 save_failed 处理（不是静默成功）。
      throw StateError('接受候选写入失败：候选已被并发改动');
    }
    wrote = true;
    figuresCommitted = pendingFigureWrite != null;
    var acceptedCopy = fresh.copyWith(
      ocrStem: split.stemText,
      ocrSplitStatus: split.status.label,
      contentVersion: fresh.contentVersion + 1,
      ocrRaw: acceptedJson,
      ocrFigures: encodeOcrFigures(figuresToStore),
    );
    if (plan.writeType) {
      acceptedCopy = acceptedCopy.copyWith(
        questionTypeSource: plan.questionTypeSource,
        clearQuestionType: plan.questionType == null,
      );
      if (plan.questionType != null) {
        acceptedCopy = acceptedCopy.copyWith(
          questionType: plan.questionType,
        );
      }
    }
    if (plan.writeTags) {
      acceptedCopy = acceptedCopy.copyWith(
        questionBackgroundTags: plan.backgroundTags,
        questionBackgroundTagsSource: plan.backgroundTagsSource,
      );
    }
    accepted = acceptedCopy;
    });
  } catch (_) {
    // 事务回滚（行数 ≠1 等）：清理刚写的图块文件，再原样外抛，
    // 数据库不留下无效引用。
    final pending = pendingFigureWrite;
    if (pending != null) {
      await rollbackFigureFiles(
        pending.registeredPaths,
        dataDir: AppDatabase.dataDirectoryPath(),
      );
    }
    rethrow;
  }
  // 拒绝在事务提交后再抛（hash_mismatch 的标 stale 写入已提交，
  // 其余拒绝本来就没有写入）；成功路径的事件也在提交后发。
  if (rejection != null) {
    final pending = pendingFigureWrite;
    if (pending != null && !figuresCommitted) {
      await rollbackFigureFiles(
        pending.registeredPaths,
        dataDir: AppDatabase.dataDirectoryPath(),
      );
    }
    if (wrote) _emitQuestionChanged(question.id);
    throw rejection!;
  }
  if (accepted == null) {
    final pending = pendingFigureWrite;
    if (pending != null) {
      await rollbackFigureFiles(
        pending.registeredPaths,
        dataDir: AppDatabase.dataDirectoryPath(),
      );
    }
    throw StateError('接受候选写入失败：未写库');
  }
  if (pendingFigureWrite != null) {
    commitFigureFiles(pendingFigureWrite!.registeredPaths);
  }
  _emitQuestionChanged(question.id);
  return AcceptedCandidate(
    question: accepted!,
    unmatchedManualIds: unmatchedManualIds,
  );
}

/// Drift 行 → 模型（与 db_questions.dart 的 _questionFromDb 同口径；
/// 那是 database 库的私有函数，本文件不在同一库内，按同一映射手写
/// 一份——行里有什么字段就原样带上，只改接受要写的 4 列）。
Question _questionFromRow(DbQuestion r) => Question(
  id: r.id,
  title: r.title,
  subjectId: r.subjectId,
  folderIds: r.folderIds,
  examId: r.examId,
  knowledgePointIds: r.knowledgeIds,
  errorTypes: r.errorTypes,
  customErrorTypes: r.customErrorTypes,
  tags: r.tags,
  answer: r.answer,
  explanation: r.explanation,
  notes: r.notes,
  reviewCount: r.reviewCount,
  isOrganized: r.isOrganized == 1,
  isDemo: r.isDemo == 1,
  isFavorite: r.isFavorite == 1,
  isArchived: r.isArchived == 1,
  reviewJoined: r.reviewJoined == 1,
  createdAt: DateTime.fromMillisecondsSinceEpoch(r.createdAt),
  sliceKind: r.sliceKind,
  sliceText: r.sliceText,
  sourcePath: r.sourcePath,
  sourceKind: r.sourceKind,
  sourcePage: r.sourcePage,
  pageImagePath: r.pageImagePath,
  slicePath: r.slicePath,
  sliceWidth: r.sliceWidth,
  sliceHeight: r.sliceHeight,
  ocrRaw: r.ocrRaw,
  ocrStem: r.ocrStem,
  ocrSplitStatus: r.ocrSplitStatus,
  ocrManualEdited: r.ocrManualEdited == 1,
  contentVersion: r.contentVersion,
  // 十四批 M1：题型两维 + 答案版本（行里有什么字段就原样带上）。
  questionType: r.questionType,
  questionTypeSource: r.questionTypeSource,
  questionBackgroundTags: r.questionBackgroundTags,
  questionBackgroundTagsSource: r.questionBackgroundTagsSource,
  ocrFigures: r.ocrFigures,
  correctOption: r.correctOption,
  optionLabels: r.optionLabels,
  optionLabelsConfirmed: r.optionLabelsConfirmed == 1,
  answerVersion: r.answerVersion,
);

/// 写后发一次题目变更事件（与旧流程里 repo.save 发的事件同口径，
/// 见 AppDatabaseQuestions.upsertQuestion；只在事务提交后调）。
void _emitQuestionChanged(String questionId) {
  DataChangeBus.instance.emit(
    DataChangeEvent(
      kinds: const {DataChangeKind.badges, DataChangeKind.questions},
      questionId: questionId,
    ),
  );
}

/// 删除单个图块（十四批 M2，纠错编辑器用）：只更新数据库引用
/// （`ocr_figures` 去掉该项），content_version +1（图块变化）；
/// 旧文件不立即删，进入孤儿清理（见图块文件生命周期统一规则第 1 条）。
/// 图块不存在时原样返回（不动版本）。调用方经 repo.save 落库——
/// 版本由 upsert 的版本权威按实际内容变化统一计算（只 +1 一次）。
Question deleteFigureFromQuestion(Question question, String figureId) {
  final figures = parseOcrFigures(question.ocrFigures);
  final kept = figures.where((f) => f.id != figureId).toList();
  if (kept.length == figures.length) return question;
  return question.copyWith(
    ocrFigures: encodeOcrFigures(kept),
    contentVersion: question.contentVersion + 1,
  );
}

/// 图块换位（Win11 反馈包 3，整理页/详情页共用）：按调用方给的新顺序
/// 重排图块（[reorderFigures]，被拖图块记 manual + 落点），只更新
/// ocr_figures 引用，content_version +1；裁图文件不动。顺序非法
/// （不是原集合的排列 / 含未知 ID）时抛 [ArgumentError]，调用方按
/// 保存失败处理、编辑器回滚到原顺序。调用方经 repo.save 落库——
/// 版本由 upsert 的版本权威按实际内容变化统一计算（只 +1 一次，
/// 与 [deleteFigureFromQuestion] 同款）。
/// [movedTextAt] 是 manual 落点字符串（Q2 REV2 §5.1：`"h"` 或 `"h:s"`）。
Question reorderFiguresInQuestion(
  Question question,
  List<String> orderedFigureIds,
  String movedFigureId,
  String movedTextAt,
) {
  final reordered = reorderFigures(
    parseOcrFigures(question.ocrFigures),
    orderedIds: orderedFigureIds,
    movedFigureId: movedFigureId,
    manualTextAt: movedTextAt,
  );
  return question.copyWith(
    ocrFigures: encodeOcrFigures(reordered),
    contentVersion: question.contentVersion + 1,
  );
}

/// 忽略候选：只把 raw 里的候选状态写 ignored（原始结果不丢），
/// contentVersion +1。无候选 / 已接受 / 已忽略 / 已 stale 时原样返回
/// （不写库、不动版本；重复忽略是空操作）。
Question dismissOcrCandidateFlag(Question question) {
  final raw = GlmOcrRawData.tryParse(question.ocrRaw);
  if (raw == null || raw.candidateStatus != OcrCandidateStatus.pending) {
    return question;
  }
  return question.copyWith(
    ocrRaw: raw
        .withCandidateStatus(OcrCandidateStatus.ignored)
        .toJsonString(),
    contentVersion: question.contentVersion + 1,
  );
}

/// 读一道题的候选题干（不改任何状态；页面在“编辑中 OCR 回来了”
/// 的守门分支里用它取候选，不碰 Notifier 状态）。
/// 无候选、题目不存在、候选 input_hash 与当前切片不一致、或切片文件
/// 不存在时返回 null。hash 不一致时顺手把库里候选标 stale
/// （best-effort，写失败静默——接受时还会再验一次）。
/// 注意（十三批 P1 第二轮）：这里的标 stale 仍走先读后写的 repo.save，
/// 与 [acceptCandidateStem] 的事务内条件更新不同——它是预览 helper，
/// 调用方是拿 fake repo 的 widget 守门路径，改成走真实库会扩大本批
/// 范围；接受时原子重验兜底，误标窗口只影响一次预览展示。
Future<String?> candidateStemForQuestion(
  QuestionRepository repo,
  String questionId,
) async {
  final question = await repo.questionById(questionId);
  if (question == null) return null;
  final raw = GlmOcrRawData.tryParse(question.ocrRaw);
  if (raw == null || raw.candidateStatus != OcrCandidateStatus.pending) {
    return null;
  }
  if (raw.inputHash != null) {
    final currentHash = await _currentSliceHash(question);
    if (currentHash == null) return null;
    if (raw.inputHash != currentHash) {
      try {
        final stale = question.copyWith(
          ocrRaw: raw
              .withCandidateStatus(OcrCandidateStatus.stale)
              .toJsonString(),
          contentVersion: question.contentVersion + 1,
        );
        await repo.save(stale);
      } catch (_) {}
      return null;
    }
  }
  return splitStem(raw.mdResults).stemText;
}

/// 切片换了之后把旧候选标 stale（纯函数；重框/自愈成功后调）：
/// 只有 pending 候选、且它的 inputHash 与 [currentHash] 不一致时才改
/// （状态写 stale，contentVersion +1；其余情况原样返回，不动版本）。
/// content_version 不一致不标 stale——用户只改了题干、切片没变时
/// 候选仍可保留给用户比较（GPT §2.3 的表）。
Question markCandidateStale(Question question, String currentHash) {
  final raw = GlmOcrRawData.tryParse(question.ocrRaw);
  if (raw == null ||
      raw.candidateStatus != OcrCandidateStatus.pending ||
      raw.inputHash == currentHash) {
    return question;
  }
  return question.copyWith(
    ocrRaw: raw
        .withCandidateStatus(OcrCandidateStatus.stale)
        .toJsonString(),
    contentVersion: question.contentVersion + 1,
  );
}

/// 当前切片文件的 SHA-256；无切片路径或文件读不到时返回 null。
Future<String?> _currentSliceHash(Question question) =>
    _currentSliceHashForPath(question.slicePath);

/// 按切片相对路径算 SHA-256（事务内用事务内读到的 slice_path 调，
/// 不拿调用方传进来的旧快照）；无路径或文件读不到时返回 null。
Future<String?> _currentSliceHashForPath(String? slicePath) async {
  if (slicePath == null || slicePath.isEmpty) return null;
  final absPath = AppDatabase.resolveDataPath(slicePath);
  if (absPath == null) return null;
  final file = File(absPath);
  if (!await file.exists()) return null;
  try {
    return await sha256HexOfFile(file);
  } catch (_) {
    return null;
  }
}

/// 为一道题建 OCR 任务（重框成功后、手动“重新识别”时调 M3 的入队接口）。
///
/// 契约（十三批 P1-1 冻结；P1-2 的 worker 只改调用点、不改这个函数，
/// 靠这份契约接手）：
/// - Future 正常完成、值为 [OcrJob]：任务已持久化入队；
/// - Future 正常完成、值为 null：无切片（slicePath 为空或文件不存在），
///   没建任务——不是失败，调用方不因此报错；
/// - Future 以异常完成：读盘/写库失败（入队失败），调用方必须处理
///   （P1-2：await 并向用户展示“题目已更新，OCR 未入队”+重试入口），
///   不得静默吞掉。`unawaited` 调用时须挂 onError 兜底，避免未处理
///   的异步异常。
/// 切片变了才建新行：旧任务由 worker 应用前的哈希校验丢弃
/// （hash_mismatch），不自动覆盖；人工改过的内容仍走候选保护。
/// 入队后 kick 已启动的 worker（在跑就立即唤醒，不等 5 秒轮询）。
Future<OcrJob?> enqueueOcrForQuestion(AppDatabase db, Question question) async {
  final worker = OcrWorker.instanceOrNull ?? OcrWorker(database: db);
  final job = await worker.enqueueForQuestion(question);
  if (job != null) worker.kick();
  return job;
}
