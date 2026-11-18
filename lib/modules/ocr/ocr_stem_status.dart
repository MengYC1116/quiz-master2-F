// 十三批 M5：识别题干状态推导（纯函数，无 UI、无网络、无数据库依赖）。
//
// 状态只从两处推导：该题的 ocr_jobs 行（最新一条）+ Question 的 OCR 字段
//（ocr_stem / ocr_raw / ocr_manual_edited）。GPT 评审 §3.3 的状态表：
// 等待识别 / 识别中 / 等待设置 API Key / 稍后自动重试 / 识别完成 /
// 识别失败 / 已手动修改。
//
// 铁律（任务 + GPT §3.3）：没 key 时绝不能显示“识别中”，必须显示
// “等待设置 API Key”——running 的任务 + 无 key 也一样（worker 没 key
// 时根本不发请求，只排队；running 行只可能是旧 worker 的残留租约）。
// 候选（has_unseen_candidate）不单独成状态：它由 [hasPendingOcrCandidate]
// 另行提示（“有新的识别结果”横幅），不改变本状态。

import '../../models/models.dart';
import '../../services/glm_ocr_client.dart';

/// 识别题干状态（界面显示用，见 [OcrStemStatusLabel.label]）。
enum OcrStemStatus {
  /// 已排队，尚未开始（有 pending 任务且未到退避时间，或无任务且有 key）。
  pending,

  /// 正在请求 GLM-OCR（最新任务 running，且已设置 key）。
  running,

  /// 没有 API Key（或 key 无效）：只排队不发请求，等用户在设置里填写。
  waitingForKey,

  /// 可重试失败后在退避期内：稍后自动重试（pending + available_at 未到）。
  retryPending,

  /// 识别完成（最新任务 completed；或无任务但已有题干/原始结果）。
  /// 题干为空但原始结果在（LaTeX 不平衡）时也是完成，走原图回退，
  /// 不是失败——见 [OcrStemStatus.completed] 的调用方注释。
  completed,

  /// 识别失败（最新任务 failed，且不是 key 问题；可手动重试）。
  failed,

  /// 用户手动改过题干（ocr_manual_edited=1）：自动结果不再直接覆盖。
  manuallyEdited,
}

/// [OcrStemStatus] 的中文显示名（界面直接用，不另写文案）。
extension OcrStemStatusLabel on OcrStemStatus {
  String get label => switch (this) {
    OcrStemStatus.pending => '等待识别',
    OcrStemStatus.running => '识别中',
    OcrStemStatus.waitingForKey => '等待设置 API Key',
    OcrStemStatus.retryPending => '稍后自动重试',
    OcrStemStatus.completed => '识别完成',
    OcrStemStatus.failed => '识别失败',
    OcrStemStatus.manuallyEdited => '已手动修改',
  };
}

/// 推导一道题的识别题干状态。
///
/// [jobs] 是该题的 ocr_jobs 行（最新在前，见 `ocrJobsForQuestion`；
/// 顺序不对时本函数按 createdAt 取最新一条，不依赖调用方排序）。
/// [hasApiKey] 是设置里是否已存 BigModel key（只问有无，不读 key 值）。
/// [now] 供单测注入时钟；生产传 null（用 DateTime.now()）。
///
/// 优先级（先判的赢）：
/// 1. 人工改过 → 已手动修改（哪怕另有任务在跑：新结果只作候选，不覆盖）。
/// 2. 最新任务 running → 有 key 才“识别中”，无 key 一律“等待设置 API Key”。
/// 3. 最新任务 pending → 无 key“等待设置 API Key”；有 key 且退避未到
///    （available_at 在未来）“稍后自动重试”；否则“等待识别”。
/// 4. 最新任务 failed → key 缺失/无效（api_key_missing / api_key_invalid）
///    “等待设置 API Key”；其余“识别失败”。
/// 5. 最新任务 completed → “识别完成”。
/// 6. 无任务：有题干或有原始结果 → “识别完成”；无 key → “等待设置 API Key”；
///    否则“等待识别”。
OcrStemStatus deriveOcrStemStatus(
  Question question, {
  required List<OcrJob> jobs,
  required bool hasApiKey,
  DateTime? now,
}) {
  if (question.ocrManualEdited) return OcrStemStatus.manuallyEdited;

  OcrJob? latest;
  for (final job in jobs) {
    if (latest == null || job.createdAt.isAfter(latest.createdAt)) {
      latest = job;
    }
  }
  final current = now ?? DateTime.now();

  if (latest != null) {
    switch (latest.status) {
      case OcrJobStatus.running:
        // 没 key 时绝不能显示“识别中”（见文件头铁律）。
        return hasApiKey
            ? OcrStemStatus.running
            : OcrStemStatus.waitingForKey;
      case OcrJobStatus.pending:
        if (!hasApiKey) return OcrStemStatus.waitingForKey;
        final availableAt = latest.availableAt;
        if (availableAt != null && availableAt.isAfter(current)) {
          return OcrStemStatus.retryPending;
        }
        return OcrStemStatus.pending;
      case OcrJobStatus.failed:
        // key 无效是“等用户修 key”，不是一次性的识别失败。
        if (latest.lastErrorCode == OcrErrorCode.apiKeyMissing ||
            latest.lastErrorCode == OcrErrorCode.apiKeyInvalid) {
          return OcrStemStatus.waitingForKey;
        }
        return OcrStemStatus.failed;
      case OcrJobStatus.completed:
        return OcrStemStatus.completed;
    }
  }

  if ((question.ocrStem ?? '').trim().isNotEmpty) {
    return OcrStemStatus.completed;
  }
  if (question.ocrRaw != null && question.ocrRaw!.isNotEmpty) {
    // 只有原始结果、没有可用题干（LaTeX 不平衡只写 raw）：识别本身
    // 已完成，走原图回退，不是失败。
    return OcrStemStatus.completed;
  }
  if (!hasApiKey) return OcrStemStatus.waitingForKey;
  return OcrStemStatus.pending;
}
