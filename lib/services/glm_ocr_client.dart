// 十三批 M3：GLM-OCR Dart 客户端。
//
// 只做一件事：把一道题的切片图发给 BigModel MaaS 的 layout_parsing 接口，
// 拿回 Markdown 文本（`md_results`）与布局块（`layout_details`）。
//
// 已验证的调用形态（见 custom.bigmodel CONNECTOR.md，2026-11-18 实测）：
//   POST https://open.bigmodel.cn/api/paas/v4/layout_parsing
//   body {"model": "glm-ocr", "file": "<data:<mime>;base64,...> data URI>"}
//   header Authorization: Bearer <key>
//   200 响应含 md_results（文本，string 或 string 列表）、layout_details、usage。
// 不要调 chat/completions 格式——它对 glm-ocr 返回 HTTP 400。
//
// 铁律：
// - key 只从 [OcrKeyStore] 读，绝不写进代码、日志、错误信息、请求体以外
//   的任何地方；本文件无任何 print/debugPrint。
// - 用户只能看到渲染好的公式：本文件只返回内部数据结构，不做任何展示；
//   LaTeX 源码只存在 [GlmOcrRawData] / ocr_raw 里，永不外露。
// - 白边在发送时才加（内存里做，不改磁盘切片）：每边 +30% 纯白边
//   （尖峰结论：30% 白边时 6/6 全对；见 glm-vs-vl16-compare.md）。
//   入队时算的 input_hash 是磁盘切片文件的哈希，与白边无关。
// - 入库前校验 LaTeX 括号平衡：见 [hasBalancedLatex]；不平衡的公式段
//   不写 ocr_stem（worker 走原图回退，见 ocr_queue.dart）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'ocr_key_store.dart';

/// OCR 错误码表（存 ocr_jobs.last_error_code，M3 定稿，勿擅改含义）。
/// [OcrException.retryable] 说明该码是否可自动重试（见 ocr_queue.dart）。
class OcrErrorCode {
  /// 没填 key：只排队不发请求，不重试、不失败。
  static const String apiKeyMissing = 'api_key_missing';

  /// key 无效或无权限（HTTP 401/403）：不重试，等用户在设置里改 key。
  static const String apiKeyInvalid = 'api_key_invalid';

  /// 连接超时或单次请求超时：可重试。
  static const String timeout = 'timeout';

  /// HTTP 429：可重试，优先尊重服务端 Retry-After。
  static const String http429 = 'http_429';

  /// HTTP 5xx：可重试。
  static const String http5xx = 'http_5xx';

  /// 网络断开等 Socket 异常：可重试。
  static const String network = 'network';

  /// 图片损坏 / 解不出 / 超 10MB：不重试，直接失败。
  static const String badImage = 'bad_image';

  /// 请求参数错误（HTTP 400 等）：不重试，直接失败。
  static const String badParams = 'bad_params';

  /// 切片文件不存在：不重试，直接失败（提示重新导入或恢复图片）。
  static const String fileMissing = 'file_missing';

  /// 服务端 200 但响应体不符合约定（缺 md_results / 非 JSON）：不重试。
  static const String badResponse = 'bad_response';

  /// 应用结果前丢弃（worker 码，非客户端码）：题目已被删：不重试。
  static const String questionDeleted = 'question_deleted';

  /// 应用结果前丢弃（worker 码）：切片文件内容变了，与入队时哈希不一致。
  static const String hashMismatch = 'hash_mismatch';

  /// 应用结果前丢弃（worker 码）：任务领取后题目内容版本变了。
  static const String contentChanged = 'content_changed';

  /// worker 内部未预期的异常（如数据库读写失败）：可重试（上限 4 次），
  /// 4 次后仍失败则进 failed——重试本身是幂等的（应用前三项校验兜底）。
  static const String internalError = 'internal';

  /// 全部错误码（测试锁定：码表只增不改，旧码不复用）。
  static const Set<String> all = {
    apiKeyMissing,
    apiKeyInvalid,
    timeout,
    http429,
    http5xx,
    network,
    badImage,
    badParams,
    fileMissing,
    badResponse,
    questionDeleted,
    hashMismatch,
    contentChanged,
    internalError,
  };
}

/// OCR 一次调用失败。`message` 只写“发生了什么 + 该怎么办”，绝不含
/// key、LaTeX 原文、图片内容；`retryAfter` 仅 429 且服务端给了
/// Retry-After 秒数时有值。
class OcrException implements Exception {
  OcrException(this.code, this.message, {this.retryAfter});

  final String code;
  final String message;
  final Duration? retryAfter;

  /// 是否可自动重试（GPT 评审 §2.5 + 任务码表）：
  /// timeout / http_429 / http_5xx / network 可重试，其余一律不可。
  bool get retryable => switch (code) {
    OcrErrorCode.timeout ||
    OcrErrorCode.http429 ||
    OcrErrorCode.http5xx ||
    OcrErrorCode.network ||
    OcrErrorCode.internalError => true,
    _ => false,
  };

  @override
  String toString() => 'OcrException($code): $message';
}

/// OCR 识别器接口：worker 只依赖它，不依赖具体客户端——单测用假实现。
abstract class OcrRecognizer {
  Future<GlmOcrResult> recognize(File cropFile);
}

/// 一次识别的原始结果（内部数据，不展示）。
class GlmOcrResult {
  GlmOcrResult({
    required this.markdown,
    required this.rawData,
    this.totalTokens,
    this.transform,
  });

  /// md_results 拼成的 Markdown 文本（公式为行内 `$...$` LaTeX）。
  final String markdown;

  /// 原始结果包：md + layout_details + usage（存 questions.ocr_raw 用，
  /// 见 [GlmOcrRawData]；`layout_details` 的 bbox 原样保留，给 M5 的
  /// 公式原图回退与切分辅助信号用）。
  final GlmOcrRawData rawData;

  /// usage.total_tokens（成本统计用，可空）。
  final int? totalTokens;

  /// 十四批 M2：本次 OCR 请求的真实转换元数据（原图尺寸、请求图尺寸、
  /// 实际 padX/padY）。裁图时只用它换算，不再假定 0.30 白边。
  final OcrRequestTransform? transform;
}

/// 一次 OCR 请求的真实转换元数据（十四批 M2 P1-4 坐标契约）。
///
/// - `srcW`/`srcH`：送入请求前原图的宽高（磁盘切片原样）；
/// - `reqW`/`reqH`：实际发给 API 的图的宽高（加白边后）；
/// - `padX`/`padY`：实际加的白边像素（未加白边时为 0）。
/// 随 OCR 结果包保存（进 `ocr_raw` 的 `transform` 键，或图块来源字段），
/// 供裁图时使用。**不再保存固定的 padding_fraction 0.30**：裁图时只用
/// 本次请求保存的真实元数据换算，不重新假设所有图片都加了 30% 白边。
class OcrRequestTransform {
  const OcrRequestTransform({
    required this.srcW,
    required this.srcH,
    required this.reqW,
    required this.reqH,
    required this.padX,
    required this.padY,
  });

  final int srcW;
  final int srcH;
  final int reqW;
  final int reqH;
  final int padX;
  final int padY;

  Map<String, Object?> toJson() => {
    'src_w': srcW,
    'src_h': srcH,
    'req_w': reqW,
    'req_h': reqH,
    'pad_x': padX,
    'pad_y': padY,
  };

  static OcrRequestTransform? tryParse(Object? value) {
    if (value is! Map) return null;
    final srcW = value['src_w'];
    final srcH = value['src_h'];
    final reqW = value['req_w'];
    final reqH = value['req_h'];
    final padX = value['pad_x'];
    final padY = value['pad_y'];
    if (srcW is! num ||
        srcH is! num ||
        reqW is! num ||
        reqH is! num ||
        padX is! num ||
        padY is! num) {
      return null;
    }
    return OcrRequestTransform(
      srcW: srcW.toInt(),
      srcH: srcH.toInt(),
      reqW: reqW.toInt(),
      reqH: reqH.toInt(),
      padX: padX.toInt(),
      padY: padY.toInt(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OcrRequestTransform &&
      srcW == other.srcW &&
      srcH == other.srcH &&
      reqW == other.reqW &&
      reqH == other.reqH &&
      padX == other.padX &&
      padY == other.padY;

  @override
  int get hashCode => Object.hash(srcW, srcH, reqW, reqH, padX, padY);
}

/// 候选状态（十三批 P1-1，GPT §2.3）：一份 ocr_raw 包里的候选处于
/// 哪种状态。JSON 里存枚举名（`candidate_status`）。
/// - [none]：包里没有候选（刚自动应用完、或 LaTeX 不平衡原图回退）。
/// - [pending]：等待用户处理（唯一可接受的状态）。
/// - [accepted]：用户已接受（写进 ocr_stem 后）。
/// - [ignored]：用户已忽略。
/// - [stale]：候选的 input_hash 与当前切片不一致，来自旧切片，
///   绝不能作为可接受候选展示或接受。
enum OcrCandidateStatus { none, pending, accepted, ignored, stale }

/// ocr_raw 的 JSON 包格式（v4 schema 内解决“候选结果”存放，见
/// ocr_queue.dart 的候选判定节；M5 按此解析，不要自己拼字段）。
///
/// ```json
/// {"md_results": "...", "layout_details": [...], "usage": {...},
///  "candidate_status": "pending", "has_unseen_candidate": true,
///  "job_id": "ocr-...", "input_hash": "…", "claimed_content_version": 7,
///  "created_at": 1731..., "completed_at_ms": 1731...}
/// ```
/// - `md_results` / `layout_details` / `usage` 是 GLM 原样返回的内容。
/// - `candidate_status`（十三批 P1-1）：候选状态，见
///   [OcrCandidateStatus]；`has_unseen_candidate` 是它的旧版同义字段
///   （= status 是否 pending），仅为兼容而保留读写，新逻辑一律以
///   `candidate_status` 为准。
/// - `job_id`：产出这份 raw 的任务（排障用）。
/// - `input_hash`：产出这份 raw 的任务所用的切片 SHA-256（候选的
///   来源身份；接受时必须与当前切片 hash 一致，否则标 stale 拒绝）。
/// - `claimed_content_version`：任务领取时题目的 content_version
///   （候选的来源身份；接受时不要求它仍等于当前版本——用户人工改过
///   题干但切片没变时，正是需要比较并主动接受的情形，GPT §2.3）。
/// - `created_at` 与 `completed_at_ms`：同一值——本包没有独立的创建
///   时间字段，`completed_at_ms`（worker 写完这份 raw 的毫秒时间戳）
///   就是创建时间；写包时两个键同值，读包时优先 `created_at`、
///   缺失时回退 `completed_at_ms`（十三批前旧包只有后者）。
class GlmOcrRawData {
  GlmOcrRawData({
    required this.mdResults,
    this.layoutDetails = const [],
    this.usage = const {},
    this.jobId,
    this.completedAtMs,
    this.inputHash,
    this.claimedContentVersion,
    this.candidateStatus = OcrCandidateStatus.none,
    this.transform,
  });

  final String mdResults;
  final List<Object?> layoutDetails;
  final Map<String, Object?> usage;
  final String? jobId;
  final int? completedAtMs;

  /// 候选的来源身份：产出这份 raw 的任务所用的切片 SHA-256。
  final String? inputHash;

  /// 候选的来源身份：任务领取时题目的 content_version。
  final int? claimedContentVersion;

  /// 候选状态（见 [OcrCandidateStatus]）。
  final OcrCandidateStatus candidateStatus;

  /// 十四批 M2：本次 OCR 请求的真实转换元数据（原图/请求图尺寸、
  /// 实际 padX/padY）。旧包没有该键时为 null，图块派生时安全弃用。
  final OcrRequestTransform? transform;

  /// 旧版同义字段：= candidateStatus 是否 pending。仅为兼容而保留，
  /// 新逻辑一律读 [candidateStatus]。
  bool get hasUnseenCandidate =>
      candidateStatus == OcrCandidateStatus.pending;

  /// 候选包创建时间（毫秒时间戳）= [completedAtMs]（见类注释：
  /// 本包无独立创建时间字段，两者同一值）。
  int? get createdAtMs => completedAtMs;

  Map<String, Object?> toJson() => {
    'md_results': mdResults,
    'layout_details': layoutDetails,
    'usage': usage,
    'candidate_status': candidateStatus.name,
    'has_unseen_candidate': hasUnseenCandidate,
    if (jobId != null) 'job_id': jobId,
    if (inputHash != null) 'input_hash': inputHash,
    if (claimedContentVersion != null)
      'claimed_content_version': claimedContentVersion,
    if (completedAtMs != null) 'created_at': completedAtMs,
    if (completedAtMs != null) 'completed_at_ms': completedAtMs,
    // 十四批 M2：本次请求的真实转换元数据（裁图换算用）。
    if (transform != null) 'transform': transform!.toJson(),
  };

  /// 序列化（存 ocr_raw 用）。失败（不可序列化值）时抛，不静默丢数据。
  String toJsonString() => jsonEncode(toJson());

  /// 解析 ocr_raw。内容不是本格式（旧数据 / 手写）时返回 null，
  /// 不抛——调用方按“无原始结果”处理。
  /// 旧包（十三批 P1-1 之前，只有 `has_unseen_candidate`、没有
  /// `candidate_status`）按旧标志换算：true → pending，false → none。
  static GlmOcrRawData? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return null;
      final md = decoded['md_results'];
      if (md is! String) return null;
      final layout = decoded['layout_details'];
      final usage = decoded['usage'];
      final statusRaw = decoded['candidate_status'];
      final OcrCandidateStatus status;
      if (statusRaw is String) {
        status = OcrCandidateStatus.values.firstWhere(
          (s) => s.name == statusRaw,
          orElse: () => decoded['has_unseen_candidate'] == true
              ? OcrCandidateStatus.pending
              : OcrCandidateStatus.none,
        );
      } else {
        status = decoded['has_unseen_candidate'] == true
            ? OcrCandidateStatus.pending
            : OcrCandidateStatus.none;
      }
      final createdAt = decoded['created_at'];
      final completedAt = decoded['completed_at_ms'];
      return GlmOcrRawData(
        mdResults: md,
        layoutDetails: layout is List ? layout : const [],
        usage: usage is Map<String, Object?> ? usage : const {},
        jobId: decoded['job_id'] as String?,
        completedAtMs: createdAt is int
            ? createdAt
            : (completedAt as int?),
        inputHash: decoded['input_hash'] as String?,
        claimedContentVersion: decoded['claimed_content_version'] as int?,
        candidateStatus: status,
        transform: OcrRequestTransform.tryParse(decoded['transform']),
      );
    } catch (_) {
      return null;
    }
  }

  /// 候选包换一个状态（其余字段原样；接受/忽略/标 stale 时用）。
  GlmOcrRawData withCandidateStatus(OcrCandidateStatus status) =>
      GlmOcrRawData(
        mdResults: mdResults,
        layoutDetails: layoutDetails,
        usage: usage,
        jobId: jobId,
        completedAtMs: completedAtMs,
        inputHash: inputHash,
        claimedContentVersion: claimedContentVersion,
        candidateStatus: status,
        transform: transform,
      );

  /// 补来源身份（worker 写库前调）：input_hash 与 claimed_content_version
  /// 是任务的属性，不是识别结果本身的属性，客户端不填、worker 在
  /// 应用结果时补上。已有的值不被空值覆盖。
  GlmOcrRawData withProvenance({
    String? inputHash,
    int? claimedContentVersion,
  }) => GlmOcrRawData(
    mdResults: mdResults,
    layoutDetails: layoutDetails,
    usage: usage,
    jobId: jobId,
    completedAtMs: completedAtMs,
    inputHash: inputHash ?? this.inputHash,
    claimedContentVersion: claimedContentVersion ?? this.claimedContentVersion,
    candidateStatus: candidateStatus,
    transform: transform,
  );

  GlmOcrRawData withCandidate({
    required String jobId,
    required int completedAtMs,
    String? inputHash,
    int? claimedContentVersion,
  }) => GlmOcrRawData(
    mdResults: mdResults,
    layoutDetails: layoutDetails,
    usage: usage,
    candidateStatus: OcrCandidateStatus.pending,
    jobId: jobId,
    completedAtMs: completedAtMs,
    inputHash: inputHash ?? this.inputHash,
    claimedContentVersion: claimedContentVersion ?? this.claimedContentVersion,
    transform: transform,
  );

  GlmOcrRawData withoutCandidate() => GlmOcrRawData(
    mdResults: mdResults,
    layoutDetails: layoutDetails,
    usage: usage,
    jobId: jobId,
    completedAtMs: completedAtMs,
    inputHash: inputHash,
    claimedContentVersion: claimedContentVersion,
    transform: transform,
  );

  /// 补本次请求的真实转换元数据（客户端 recognize() 在返回结果前调）。
  GlmOcrRawData withTransform(OcrRequestTransform value) => GlmOcrRawData(
    mdResults: mdResults,
    layoutDetails: layoutDetails,
    usage: usage,
    jobId: jobId,
    completedAtMs: completedAtMs,
    inputHash: inputHash,
    claimedContentVersion: claimedContentVersion,
    candidateStatus: candidateStatus,
    transform: value,
  );
}

/// GLM layout_parsing 的一次 HTTP 往返（可注入的发包层，单测用假实现）。
class GlmOcrHttpResponse {
  GlmOcrHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  final int statusCode;

  /// 响应头（键已小写；只读 Retry-After 用）。
  final Map<String, String> headers;
  final String body;
}

/// 发包函数签名：`sender(uri, headers, body)` 返回状态码 + 头 + 体。
typedef GlmOcrRequestSender =
    Future<GlmOcrHttpResponse> Function(
      Uri uri,
      Map<String, String> headers,
      String body,
    );

/// GLM-OCR 客户端（MaaS layout_parsing，见文件头调用形态）。
class GlmOcrClient implements OcrRecognizer {
  GlmOcrClient({
    OcrKeyStore? keyStore,
    GlmOcrRequestSender? sender,
    this.connectTimeout = const Duration(seconds: 15),
    this.requestTimeout = const Duration(seconds: 120),
    this.endpointOverride,
  }) : _keyStore = keyStore ?? OcrKeyStore(),
       // _sender 是私有字段，初始化形参会改名，外部 `sender:` 传参点会断。
       // ignore: prefer_initializing_formals
       _sender = sender;

  /// 接口地址（MaaS layout_parsing，勿改成 chat/completions）。
  static final Uri endpoint = Uri.parse(
    'https://open.bigmodel.cn/api/paas/v4/layout_parsing',
  );

  /// 仅单测用：覆盖 [endpoint]（验证默认发包层的超时强关时指到本地
  /// 测试服务器）；生产恒为 null。
  final Uri? endpointOverride;

  static const String model = 'glm-ocr';

  /// 连接超时（GPT 评审 §2.4 建议值）。
  final Duration connectTimeout;

  /// 单次请求超时（GPT 评审建议 90–120 秒；取上限 120 秒）。
  final Duration requestTimeout;

  /// 发送前白边比例：每边加原图 30% 的纯白边（尖峰结论）。
  static const double paddingFraction = 0.30;

  /// 服务端单文件上限 10MB（超了直接报 bad_image，不发请求）。
  static const int maxImageBytes = 10 * 1024 * 1024;

  final OcrKeyStore _keyStore;

  /// 注入的发包层（单测用假实现）；null 时走 [_defaultSender]。
  final GlmOcrRequestSender? _sender;

  @override
  Future<GlmOcrResult> recognize(File cropFile) async {
    if (!await cropFile.exists()) {
      throw OcrException(
        OcrErrorCode.fileMissing,
        '切片文件不存在，请重新导入或恢复图片',
      );
    }
    final originalBytes = await cropFile.readAsBytes();
    // 十四批 M2：本次请求的真实转换元数据（原图尺寸、请求图尺寸、
    // 实际 padX/padY）随结果包保存，供裁图换算用，不再假定 0.30。
    final srcImage = img.decodeImage(originalBytes);
    if (srcImage == null) {
      throw OcrException(OcrErrorCode.badImage, '图片损坏，无法识别');
    }
    final padX = (srcImage.width * paddingFraction).round();
    final padY = (srcImage.height * paddingFraction).round();
    final transform = OcrRequestTransform(
      srcW: srcImage.width,
      srcH: srcImage.height,
      reqW: srcImage.width + padX * 2,
      reqH: srcImage.height + padY * 2,
      padX: padX,
      padY: padY,
    );
    final paddedBytes = addWhitePadding(originalBytes);
    if (paddedBytes.length > maxImageBytes) {
      throw OcrException(
        OcrErrorCode.badImage,
        '图片过大（加白边后超过 10MB），无法识别',
      );
    }
    final apiKey = await _keyStore.getApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw OcrException(
        OcrErrorCode.apiKeyMissing,
        '未设置 BigModel API Key，请在设置里填写',
      );
    }
    final body = jsonEncode({
      'model': model,
      'file':
          'data:image/png;base64,${base64Encode(paddedBytes)}',
    });
    final GlmOcrHttpResponse response;
    try {
      // 未注入 sender 时走默认 HttpClient 发包层（内部自带超时强关，
      // 见 [_defaultSender]）；注入的 sender 只包一层 timeout
      //（外部发包层无法强制取消，本层只能等它自己结束）。
      response = await (_sender ?? _defaultSender)(
        endpointOverride ?? endpoint,
        {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body,
      ).timeout(requestTimeout);
    } on TimeoutException {
      throw OcrException(
        OcrErrorCode.timeout,
        '识别请求超时（${requestTimeout.inSeconds} 秒），稍后自动重试',
      );
    } on SocketException {
      throw OcrException(OcrErrorCode.network, '网络断开，稍后自动重试');
    } on HttpException {
      throw OcrException(OcrErrorCode.network, '网络异常，稍后自动重试');
    }
    final parsed = _parseResponse(response);
    return GlmOcrResult(
      markdown: parsed.markdown,
      rawData: parsed.rawData.withTransform(transform),
      totalTokens: parsed.totalTokens,
      transform: transform,
    );
  }

  GlmOcrResult _parseResponse(GlmOcrHttpResponse response) {
    final status = response.statusCode;
    if (status == 200) {
      final Map<String, Object?> payload;
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, Object?>) {
          throw const FormatException('not an object');
        }
        payload = decoded;
      } catch (_) {
        throw OcrException(
          OcrErrorCode.badResponse,
          '识别服务返回了无法解析的结果',
        );
      }
      final md = payload['md_results'];
      if (md == null) {
        throw OcrException(
          OcrErrorCode.badResponse,
          '识别服务返回的结果里没有识别文本',
        );
      }
      final markdown = md is List
          ? md.map((e) => e.toString()).join('\n')
          : md.toString();
      final layout = payload['layout_details'];
      final usage = payload['usage'];
      final totalTokens = usage is Map<String, Object?>
          ? usage['total_tokens'] as int?
          : null;
      return GlmOcrResult(
        markdown: markdown,
        rawData: GlmOcrRawData(
          mdResults: markdown,
          layoutDetails: layout is List ? layout : const [],
          usage: usage is Map<String, Object?> ? usage : const {},
        ),
        totalTokens: totalTokens,
      );
    }
    if (status == 401 || status == 403) {
      throw OcrException(
        OcrErrorCode.apiKeyInvalid,
        'API Key 无效或无权限，请在设置里检查',
      );
    }
    if (status == 429) {
      final retryAfter = _parseRetryAfter(response.headers['retry-after']);
      throw OcrException(
        OcrErrorCode.http429,
        '识别服务繁忙（429），稍后自动重试',
        retryAfter: retryAfter,
      );
    }
    if (status >= 500 && status <= 599) {
      throw OcrException(
        OcrErrorCode.http5xx,
        '识别服务暂不可用（HTTP $status），稍后自动重试',
      );
    }
    throw OcrException(
      OcrErrorCode.badParams,
      '识别请求被拒绝（HTTP $status），请检查图片与设置',
    );
  }

  Duration? _parseRetryAfter(String? value) {
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds == null || seconds < 0) return null;
    return Duration(seconds: seconds);
  }

  /// 默认发包层：dart:io HttpClient（无第三方 http 依赖）。
  /// 连接超时由 [connectTimeout] 控；整体请求超时由 [requestTimeout] 控。
  /// 十三批 P1-1（GPT §3.1）：`Future.timeout` 本身不等于底层请求取消——
  /// 超时时必须强制关闭 client（`close(force: true)`），否则超时后旧
  /// 请求仍占连接、还可能继续产生计费；超时后整个 client 丢弃，不复用。
  Future<GlmOcrHttpResponse> _defaultSender(
    Uri uri,
    Map<String, String> headers,
    String body,
  ) async {
    final client = HttpClient();
    client.connectionTimeout = connectTimeout;
    try {
      return await _sendWithClient(
        client,
        uri,
        headers,
        body,
      ).timeout(requestTimeout, onTimeout: () {
        client.close(force: true);
        throw TimeoutException('识别请求超时', requestTimeout);
      });
    } finally {
      client.close();
    }
  }

  /// 用给定 client 发一次请求并读完响应体（[_defaultSender] 的内层，
  /// 超时强关由外层控；本函数不自己包 timeout）。
  static Future<GlmOcrHttpResponse> _sendWithClient(
    HttpClient client,
    Uri uri,
    Map<String, String> headers,
    String body,
  ) async {
    final request = await client.postUrl(uri);
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    request.add(utf8.encode(body));
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    final responseHeaders = <String, String>{};
    response.headers.forEach((name, values) {
      if (values.isNotEmpty) responseHeaders[name.toLowerCase()] = values.first;
    });
    return GlmOcrHttpResponse(
      statusCode: response.statusCode,
      headers: responseHeaders,
      body: responseBody,
    );
  }
}

/// 给切片每边加 [fraction]（默认 30%）纯白边，返回 PNG 字节。
/// 在内存里做，不改磁盘文件；解不出图时抛 [OcrException]（bad_image）。
/// 白边是纯白（255,255,255）；原图按原尺寸贴在正中央。
Uint8List addWhitePadding(Uint8List bytes, {double fraction = 0.30}) {
  final src = img.decodeImage(bytes);
  if (src == null) {
    throw OcrException(OcrErrorCode.badImage, '图片损坏，无法识别');
  }
  final padX = (src.width * fraction).round();
  final padY = (src.height * fraction).round();
  final dst = img.Image(width: src.width + padX * 2, height: src.height + padY * 2);
  img.fill(dst, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(dst, src, dstX: padX, dstY: padY);
  return img.encodePng(dst);
}

/// LaTeX 括号平衡校验（入库前，worker 调）：只校验 `$...$` / `$$...$$`
/// 公式段里的 `()` `[]` `{}` 是否配对，以及 `$` 定界符是否成对。
/// - 转义的括号（`\(` `\{` `\[` 等）不计入；`\text{...}` 里的大括号照常计
///   （它就是普通括号，配对才算合法）。
/// - 非公式的正文不管：题干里的中文括号 `（）` 不是 LaTeX 括号，不校验。
/// - 返回 true = 全部公式段括号平衡；false = 至少一段不平衡。
///   不平衡的公式段不写 ocr_stem，走原图回退（M1 FormulaView 同款回退）。
bool hasBalancedLatex(String markdown) =>
    unbalancedLatexSegments(markdown).isEmpty;

/// 返回不平衡的公式段原文（去 `$` 定界符后）。空 = 全部平衡。
/// 仅供 worker 判定与单测；调用方不得把返回值打进日志（可能含 LaTeX）。
List<String> unbalancedLatexSegments(String markdown) {
  final segments = _extractMathSegments(markdown);
  final bad = <String>[];
  for (final segment in segments) {
    if (!_isBracketBalanced(segment)) bad.add(segment);
  }
  return bad;
}

/// 抽出全部 `$...$` 与 `$$...$$` 公式段（不含定界符）。
/// `$` 个数为奇数（有不成对的定界符）时，把最后一个 `$` 之后的内容
/// 也当作一段返回——它本身就是不平衡的证据，由 [_isBracketBalanced]
/// 之外的定界符检查在调用方判定：本函数返回的段里若含孤 `$` 即不平衡。
/// 实现上用正则先取 `$$...$$` 再取 `$...$`，避免 `$$` 被拆成两个 `$`。
List<String> _extractMathSegments(String markdown) {
  final segments = <String>[];
  // 先占位处理 $$...$$：把它们替换成等长空白，再扫 $...$。
  final displayPattern = RegExp(r'\$\$(.+?)\$\$', dotAll: true);
  var masked = markdown;
  for (final m in displayPattern.allMatches(markdown)) {
    segments.add(m.group(1)!);
  }
  masked = markdown.replaceAllMapped(
    displayPattern,
    (m) => ' ' * m.group(0)!.length,
  );
  final inlinePattern = RegExp(r'\$(.+?)\$', dotAll: true);
  for (final m in inlinePattern.allMatches(masked)) {
    segments.add(m.group(1)!);
  }
  // 孤 `$`：掩掉已配对的段后还剩奇数个 `$` 即定界符不成对。
  final remainingDollars = RegExp(r'(?<!\\)\$').allMatches(masked).length;
  if (remainingDollars.isOdd) {
    segments.add('<unpaired-\$>');
  }
  return segments;
}

/// 一段公式文本里的 () [] {} 是否配对（转义括号不计）。
bool _isBracketBalanced(String segment) {
  if (segment == '<unpaired-\$>') return false;
  const pairs = {'(': ')', '[': ']', '{': '}'};
  const closers = {')', ']', '}'};
  final stack = <String>[];
  final units = segment.runes.toList();
  for (var i = 0; i < units.length; i++) {
    final ch = String.fromCharCode(units[i]);
    // 反斜杠转义：下一个字符不参与括号判定。
    if (ch == '\\') {
      i++;
      continue;
    }
    if (pairs.containsKey(ch)) {
      stack.add(ch);
    } else if (closers.contains(ch)) {
      if (stack.isEmpty) return false;
      final open = stack.removeLast();
      if (pairs[open] != ch) return false;
    }
  }
  return stack.isEmpty;
}
