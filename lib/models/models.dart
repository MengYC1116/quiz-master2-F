import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';

/// 学科：初始三科，顺序固定 数学 / 英语 / 政治（大学阶段）。
/// 封面样式 + 封面颜色存在 subjects 表里（v2 新增，学科管理页可改）。
class Subject {
  Subject({
    required this.id,
    required this.name,
    required this.color,
    required this.icon,
    this.coverStyle = 'plain',
    this.coverColor = 'blue',
  });
  final String id;
  final String name;
  final Color color;
  final String icon; // 单字图标，如 数 / 英 / 政
  final String coverStyle; // 6 种封面样式之一
  final String coverColor; // 7 种预设色之一

  static final math = Subject(
      id: 'math', name: '数学', color: const Color(0xFF2E7CF6), icon: '数');
  static final english = Subject(
      id: 'english', name: '英语', color: const Color(0xFF00A884), icon: '英');
  static final politics = Subject(
      id: 'politics', name: '政治', color: const Color(0xFFEF4444), icon: '政');
  static List<Subject> get all => [math, english, politics];
  static Subject byId(String id) =>
      all.firstWhere((s) => s.id == id, orElse: () => math);

  Subject copyWith({
    String? name,
    Color? color,
    String? coverStyle,
    String? coverColor,
  }) =>
      Subject(
        id: id,
        name: name ?? this.name,
        color: color ?? this.color,
        icon: icon,
        coverStyle: coverStyle ?? this.coverStyle,
        coverColor: coverColor ?? this.coverColor,
      );
}

/// 错题本封面 6 种样式（学科管理页按学科换）。
class CoverStyles {
  static const all = ['plain', 'lines', 'dots', 'grid', 'diagonal', 'double'];
  static const labels = {
    'plain': '纯色折角',
    'lines': '横线纹',
    'dots': '圆点',
    'grid': '方格纹',
    'diagonal': '斜纹',
    'double': '双线框',
  };
}

/// 封面 7 种预设色（只预设这 7 种，不自定义取色）。
class CoverColors {
  static const all = [
    'blue',
    'green',
    'red',
    'purple',
    'orange',
    'yellow',
    'grey'
  ];
  static const labels = {
    'blue': '蓝',
    'green': '绿',
    'red': '红',
    'purple': '紫',
    'orange': '橙',
    'yellow': '黄',
    'grey': '灰',
  };
  // 封面 7 预设色（HTML 附录 A / 学科管理封面块）。
  // 注意封面蓝 #2F7CF6 与学科蓝 #2E7CF6 不是同一个值，不要合并。
  // 值与 lib/theme/design_tokens.dart 的 CoverTokens.colors 保持一致
  //（R2 统一收口到一处）；只做表现层取值，不改 Schema。
  static const hex = {
    'blue': Color(0xFF2F7CF6),
    'green': Color(0xFF1F9D66),
    'red': Color(0xFFE0524D),
    'purple': Color(0xFF7C4DDB),
    'orange': Color(0xFFED7D31),
    'yellow': Color(0xFFD9A404),
    'grey': Color(0xFF64748F),
  };
  static Color of(String key) => hex[key] ?? hex['blue']!;
}

/// 错因解决状态（v2 复习模型，旧 1/3/7/14 与翻卡已废弃）。
/// 待解决 → 解决中（至少一次自查“已解决”，未满两次）→ 已解决
/// （同一错因在同一道题上两次自查“已解决”）；已解决满复查间隔
/// （默认 7 天）自动回来复查，复查不过打回解决中。
enum CauseStatus { pending, inProgress, solved }

extension CauseStatusLabel on CauseStatus {
  String get label => switch (this) {
        CauseStatus.pending => '待解决',
        CauseStatus.inProgress => '解决中',
        CauseStatus.solved => '已解决',
      };
}

/// “题 × 错因”解决记录：复习按错因治，一道题的每个错因各一条记录。
class CauseRecord {
  const CauseRecord({
    // 十四批 M3：数据库行 id（cause_records.id，自增主键）。内存里新造的
    // 记录（未入库）为 null；review_history.cause_id 写它（有 id 时），
    // 无 id 时回退为 '$questionId|$cause'（见 review_engine.causeStableId）。
    this.id,
    required this.questionId,
    required this.cause,
    required this.subjectId,
    this.status = CauseStatus.pending,
    this.solvedCount = 0,
    this.lastCheck,
    this.recheckDate,
    this.remedyHistory = const [],
    required this.joinedAt,
    // 十四批 M1（M3-7 的 24 小时锚点链）：上一次计入治愈次数的成功
    // 时间（毫秒时间戳）与所在会话；未计入的成功不刷新锚点；
    // “未解决”重置时两者清空；v4→v5 迁移后旧行均为 NULL。
    this.lastCountedSuccessAt,
    this.lastCountedSessionId,
  });

  final int? id;
  final String questionId;
  final String cause;
  final String subjectId;
  final CauseStatus status;
  final int solvedCount; // 同一错因同一道题自查“已解决”的累计次数
  final DateTime? lastCheck;
  final DateTime? recheckDate;
  final List<String> remedyHistory; // 每次写补救的内容（带日期），新→旧
  final DateTime joinedAt; // 加入复习的时间，列表按它排
  final int? lastCountedSuccessAt;
  final String? lastCountedSessionId;

  /// 是否到了复查时间：已解决且复查日 ≤ 今天。
  bool get isRecheckDue {
    if (status != CauseStatus.solved || recheckDate == null) return false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(
        recheckDate!.year, recheckDate!.month, recheckDate!.day);
    return !d.isAfter(today);
  }

  CauseRecord copyWith({
    int? id,
    CauseStatus? status,
    int? solvedCount,
    DateTime? lastCheck,
    DateTime? recheckDate,
    List<String>? remedyHistory,
    DateTime? joinedAt,
    int? lastCountedSuccessAt,
    String? lastCountedSessionId,
    bool clearRecheckDate = false,
    bool clearCountedAnchors = false,
  }) {
    return CauseRecord(
      id: id ?? this.id,
      questionId: questionId,
      cause: cause,
      subjectId: subjectId,
      status: status ?? this.status,
      solvedCount: solvedCount ?? this.solvedCount,
      lastCheck: lastCheck ?? this.lastCheck,
      recheckDate:
          clearRecheckDate ? null : (recheckDate ?? this.recheckDate),
      remedyHistory: remedyHistory ?? this.remedyHistory,
      joinedAt: joinedAt ?? this.joinedAt,
      lastCountedSuccessAt: clearCountedAnchors
          ? null
          : (lastCountedSuccessAt ?? this.lastCountedSuccessAt),
      lastCountedSessionId: clearCountedAnchors
          ? null
          : (lastCountedSessionId ?? this.lastCountedSessionId),
    );
  }
}

/// 复习队列的一项：题 + 错因（§3.4）。
/// 以前队列是 `List<String>`，项拼成 `"questionId|cause"` 再用
/// `split('|')` 解析；自定义错因里一旦含 `|` 或 `,` 就切错。
/// 改成对象后数据库里走 JSON 对象数组（见 database.dart 的
/// encodeQueue / decodeQueue），值里含什么分隔符都不怕。
class ReviewQueueItem {
  const ReviewQueueItem({required this.questionId, required this.cause});

  final String questionId;
  final String cause;

  @override
  bool operator ==(Object other) =>
      other is ReviewQueueItem &&
      other.questionId == questionId &&
      other.cause == cause;

  @override
  int get hashCode => Object.hash(questionId, cause);
}

/// 复习会话断点（单行，id = 1）：暂停时存下队列与位置，
/// 下次进复习页从断的那个错因继续。
/// 十四批 M3（M3-10 轻量会话持久化）：sessionId/mode/skips/
/// perQuestionState 与 review_state 表的 v5 扩展列对应；全局同一时间
/// 只允许一个活动或暂停会话。perQuestionState 以题 id 为键，每题存
/// question_submission_id + answer_version_at_start +
/// content_version_at_start + stage + attemptId + 跳过/作答/核对/
/// verdict 状态（JSON 解码后的 Map，见 review_engine.encodePerQuestionState）。
class ReviewSessionState {
  const ReviewSessionState({
    required this.queue,
    required this.position,
    required this.updatedAt,
    this.sessionId,
    this.mode,
    this.skips = const {},
    this.perQuestionState = const {},
  });
  // 队列项按解决顺序排（ReviewQueueItem，不再拼 "qid|cause" 字符串）。
  final List<ReviewQueueItem> queue;
  final int position;
  final DateTime updatedAt;
  final String? sessionId;
  final String? mode;
  final Map<String, int> skips;
  final Map<String, Map<String, Object?>> perQuestionState;
}

/// 错误类型：固定枚举 + 自定义（自定义只跟本题，下次可选，不进全局枚举）。
class ErrorTypes {
  static const fixed = ['审题失误', '概念不清', '计算错误', '方法不会', '其他'];
}

/// §6 第 4 条（已定）：仅标签名和自定义错因名两个字段禁 `,` `，` `|`，
/// 输了提示“不能含逗号或竖线”；不禁其他符号（数学、英文、中文标点、
/// 表情都允许——JSON 编码已保证数据正确，输入限制只是前端防护）。
/// 三处调用点（学科管理标签、整理/详情的自定义错因与新建标签）共用。
bool hasBannedNameSeparator(String name) =>
    name.contains(',') || name.contains('，') || name.contains('|');

/// 新建类实体的 id（SR-P2-28）：毫秒时间戳 + 8 位随机十六进制后缀。
/// 纯毫秒时间戳在同一毫秒内两次创建会撞主键、后一次覆盖前一次
///（文件夹 / 试卷 / 知识点 / 失败任务都曾是这个写法）；后缀与
/// AppDatabase.newBoxId 同款 Random.secure() 8 位十六进制，
/// 不引入 uuid 包。时间戳在前，id 仍大致按创建顺序排。
String newEntityId(String prefix) {
  final r = math.Random.secure();
  final rand8 = List.generate(
    8,
    (_) => '0123456789abcdef'[r.nextInt(16)],
  ).join();
  return '$prefix-${DateTime.now().millisecondsSinceEpoch}-$rand8';
}

/// 知识点：预置树 学科 → 章节 → 知识点（大学层级），多选不限量。
class KnowledgePoint {
  const KnowledgePoint({
    required this.id,
    required this.subjectId,
    required this.chapter,
    required this.name,
  });
  final String id;
  final String subjectId;
  final String chapter;
  final String name;
}

/// 文件夹：按学科分（v2），每科一套，预置 试卷 / 平时作业 / 模拟卷；
/// 同一科不能重名；子文件夹只一层（parentId 为空 = 顶层文件夹）。
class Folder {
  const Folder({
    required this.id,
    required this.name,
    required this.subjectId,
    this.parentId,
    this.sortOrder = 0,
  });
  final String id;
  final String name;
  final String subjectId;
  final String? parentId;
  final int sortOrder;
}

/// 试卷（来源）：独立实体，一张试卷 → 多道题。
class Exam {
  const Exam({required this.id, required this.name, this.date});
  final String id;
  final String name;
  final DateTime? date;
}

/// 一道题 = 最小单位，整题保存，永不拆分；一道题在数据层只存一份，
/// 可挂多个文件夹、多个标签。
class Question {
  Question({
    required this.id,
    required this.title,
    required this.subjectId,
    this.folderIds = const [],
    this.examId,
    this.knowledgePointIds = const [],
    this.errorTypes = const [],
    this.customErrorTypes = const [],
    this.tags = const [],
    this.answer,
    this.explanation,
    this.notes,
    this.reviewCount = 0,
    this.isOrganized = false,
    this.isDemo = false,
    this.isFavorite = false,
    this.isArchived = false,
    // 手动加入复习（治错因）：加入后复习页按错因治；取消后记录保留，
    // 再加入可续接。未整理与无错因的题加不进复习。
    this.reviewJoined = false,
    required this.createdAt,
    this.sliceKind = 'material',
    // 题干切片文字（演示用；真实数据是图片切片，无 OCR）
    this.sliceText = '',
    // §1.2(a)：真实题的图片链路（P1 只加字段与列，不接业务）。
    // sourcePath：库内源文件副本（相对数据目录）；sourceKind：'pdf'/'image'；
    // sourcePage：源文件页码（图片为 1）；pageImagePath：修框底图/详情大图
    // （PNG/JPG，图片导入保留原图）；slicePath：整题切片 PNG；
    // sliceWidth/sliceHeight：切片像素尺寸。
    this.sourcePath,
    this.sourceKind,
    this.sourcePage,
    this.pageImagePath,
    this.slicePath,
    this.sliceWidth,
    this.sliceHeight,
    // 十三批 M2（D-106）：OCR 字段。ocrRaw 是 GLM 返回的完整原始结果
    //（内部存，绝不外露）；ocrStem 是切分后题干；ocrSplitStatus 见
    // [OcrSplitStatus]；ocrManualEdited 是人工编辑标记；contentVersion
    // 是内容版本（默认 0；递增规则由 M3 定，建议每次 OCR 自动应用或
    // 人工编辑保存时 +1，供 worker 校验“任务开始后内容是否变过”）。
    this.ocrRaw,
    this.ocrStem,
    this.ocrSplitStatus = OcrSplitStatus.unsegmented,
    this.ocrManualEdited = false,
    this.contentVersion = 0,
    // 十四批 M1：题型两维 + 答案版本。questionType 是主题型（作答形式），
    // NULL = 待确认；questionTypeSource 取值 auto/manual/unclassified；
    // questionBackgroundTags 是逗号分隔的背景标签（第一版只自动生成
    // “材料”“听力”，其余为预留值），questionBackgroundTagsSource
    // 只保护背景标签，与主题型来源分离；ocrFigures 是图块 JSON（M2 写，
    // M1 只建列，默认 '[]'）；correctOption 只用于单选/判断，多选/
    // 不定项恒为 NULL；optionLabels 是 JSON 选项标签数组，NULL = 未确认；
    // optionLabelsConfirmed 须点“确认选项”才置 1（M3 用）；answerVersion
    // 是答案版本，改答案/解析/correct_option/option_labels 时 +1。
    this.questionType,
    this.questionTypeSource = 'unclassified',
    this.questionBackgroundTags = '',
    this.questionBackgroundTagsSource = 'unclassified',
    this.ocrFigures = '[]',
    this.correctOption,
    this.optionLabels,
    this.optionLabelsConfirmed = false,
    this.answerVersion = 1,
    // 十四批 M3（P1-A）：答案待重新核对标记。改标签后未在同一次保存中
    // 重新确认答案/正确选项时置 1：旧 answer/explanation/correctOption
    // 不得再作为有效标准答案展示（各处显示“标准答案待重新核对”/
    // “解析待重新核对”/“正确答案待重新核对”）；核对区按无有效标准答案
    // 处理。持久化列 answer_pending_recheck（仍属 v5）。
    this.answerPendingRecheck = false,
    // 十四批 M3（P1-A 保存时信号，不持久化、不进 Companion）：本次保存
    // 中用户已在编辑器内明确重新确认答案/正确选项（原样确认或改写后
    // 保存）。upsert 时消费它，判定是否把改标签后的旧答案置 NULL；
    // 未带信号的改标签保存一律按“未确认”处理。
    this.answerReconfirmed = false,
    // 十四批 M3（标签确认保存时信号，不持久化）：本次保存就是点
    // “确认选项”的那一次保存（标签与确认状态一起落盘）。upsert 据此
    // 区分“本次刚确认”与“旧确认状态顺带抄过来”——改标签的保存若
    // 不带本信号，option_labels_confirmed 一律清零。
    this.optionLabelsJustConfirmed = false,
  });

  final String id;
  final String title;
  final String subjectId;
  final List<String> folderIds;
  final String? examId;
  final List<String> knowledgePointIds;
  final List<String> errorTypes;
  final List<String> customErrorTypes;
  final List<String> tags;
  final String? answer;
  final String? explanation;
  final String? notes;
  final int reviewCount;
  final bool isOrganized; // 是否已在整理工作台确认过
  final bool isDemo; // 演示题标记（v1 老库遗留；v2 新库从空开始、不预置演示题，清空入口已删）
  final bool isFavorite;
  final bool isArchived;
  final bool reviewJoined;
  final DateTime createdAt;
  final String sliceKind;
  final String sliceText;
  // §1.2(a)：图片链路字段，全部可空（无图的新题/老题为空）。
  final String? sourcePath;
  final String? sourceKind; // 'pdf' / 'image'
  final int? sourcePage;
  final String? pageImagePath;
  final String? slicePath;
  final int? sliceWidth;
  final int? sliceHeight;
  // 十三批 M2：OCR 字段（列定义见 lib/data/db_schema.dart，值域见
  // [OcrSplitStatus]；LaTeX 源码只存 ocrRaw，永不展示给用户）。
  final String? ocrRaw;
  final String? ocrStem;
  final String ocrSplitStatus;
  final bool ocrManualEdited;
  final int contentVersion;
  // 十四批 M1：题型两维 + 答案版本（列定义见 lib/data/db_schema.dart）。
  final String? questionType;
  final String questionTypeSource;
  final String questionBackgroundTags;
  final String questionBackgroundTagsSource;
  final String ocrFigures;
  final String? correctOption;
  final List<String>? optionLabels;
  final bool optionLabelsConfirmed;
  final int answerVersion;
  final bool answerPendingRecheck;
  final bool answerReconfirmed;
  final bool optionLabelsJustConfirmed;

  /// P1-A 有效答案口径：待重新核对期间旧答案/解析/正确选项一律无效。
  /// 单选/判断的有效标准答案是 correctOption；多选/不定项与主观题是
  /// answer 字段。调用方按题型取其中之一，两个 getter 都先过本标记。
  String? get effectiveCorrectOption =>
      answerPendingRecheck ? null : correctOption;
  String? get effectiveAnswer => answerPendingRecheck ? null : answer;
  String? get effectiveExplanation =>
      answerPendingRecheck ? null : explanation;

  /// 本题是否有可作核验依据的软件内标准答案（M3-6 表 A/B 分流用）：
  /// 单选/判断看 correctOption；其余题型看 answer；待重新核对时一律无。
  bool get hasValidStandardAnswer {
    if (answerPendingRecheck) return false;
    if (questionType == 'choice_single' || questionType == 'true_false') {
      return correctOption != null && correctOption!.isNotEmpty;
    }
    return answer != null && answer!.trim().isNotEmpty;
  }

  /// 背景标签列表（逗号分隔存；空串 = 无标签）。
  List<String> get backgroundTagList =>
      questionBackgroundTags.isEmpty
      ? const []
      : questionBackgroundTags
            .split(',')
            .map((t) => t.trim())
            .where((t) => t.isNotEmpty)
            .toList();

  /// 全部错因（固定枚举 + 自定义）。
  /// SR2-23：保序去重——旧数据里同名自定义（如固定名“其他”又存了一份
  /// 自定义）会在详情页与错题本重复显示；新入口已拦同名，但未重保存
  /// 的旧题仍带重复。Set 保序（先固定、后自定义），一处修、全链路受益。
  List<String> get allCauses => {...errorTypes, ...customErrorTypes}.toList();

  Question copyWith({
    List<String>? folderIds,
    String? examId,
    List<String>? knowledgePointIds,
    List<String>? errorTypes,
    List<String>? customErrorTypes,
    List<String>? tags,
    String? answer,
    String? explanation,
    String? notes,
    int? reviewCount,
    bool? isOrganized,
    bool? isDemo,
    bool? isFavorite,
    bool? isArchived,
    bool? reviewJoined,
    // §1.2(a)：图片链路字段。
    String? sourcePath,
    String? sourceKind,
    int? sourcePage,
    String? pageImagePath,
    String? slicePath,
    int? sliceWidth,
    int? sliceHeight,
    // 十三批 M2：OCR 字段。
    String? ocrRaw,
    String? ocrStem,
    String? ocrSplitStatus,
    bool? ocrManualEdited,
    int? contentVersion,
    // 十四批 M1：题型两维 + 答案版本。
    String? questionType,
    String? questionTypeSource,
    String? questionBackgroundTags,
    String? questionBackgroundTagsSource,
    String? ocrFigures,
    String? correctOption,
    List<String>? optionLabels,
    bool? optionLabelsConfirmed,
    int? answerVersion,
    bool? answerPendingRecheck,
    bool? answerReconfirmed,
    bool? optionLabelsJustConfirmed,
    // 传 null 表示“保持原值”；要把字段清空时用这些标志（整理/详情页
    // 把答案、解析、笔记清空后保存必须真正清掉，不能留旧值）。
    bool clearExamId = false,
    bool clearAnswer = false,
    bool clearExplanation = false,
    bool clearNotes = false,
    bool clearSourcePath = false,
    bool clearPageImagePath = false,
    bool clearSlicePath = false,
    bool clearOcrRaw = false,
    bool clearOcrStem = false,
    bool clearQuestionType = false,
    bool clearOptionLabels = false,
    bool clearCorrectOption = false,
  }) {
    return Question(
      id: id,
      title: title,
      subjectId: subjectId,
      folderIds: folderIds ?? this.folderIds,
      examId: clearExamId ? null : (examId ?? this.examId),
      knowledgePointIds: knowledgePointIds ?? this.knowledgePointIds,
      errorTypes: errorTypes ?? this.errorTypes,
      customErrorTypes: customErrorTypes ?? this.customErrorTypes,
      tags: tags ?? this.tags,
      answer: clearAnswer ? null : (answer ?? this.answer),
      explanation: clearExplanation ? null : (explanation ?? this.explanation),
      notes: clearNotes ? null : (notes ?? this.notes),
      reviewCount: reviewCount ?? this.reviewCount,
      isOrganized: isOrganized ?? this.isOrganized,
      isDemo: isDemo ?? this.isDemo,
      isFavorite: isFavorite ?? this.isFavorite,
      isArchived: isArchived ?? this.isArchived,
      reviewJoined: reviewJoined ?? this.reviewJoined,
      createdAt: createdAt,
      sliceKind: sliceKind,
      sliceText: sliceText,
      sourcePath: clearSourcePath ? null : (sourcePath ?? this.sourcePath),
      sourceKind: sourceKind ?? this.sourceKind,
      sourcePage: sourcePage ?? this.sourcePage,
      pageImagePath:
          clearPageImagePath ? null : (pageImagePath ?? this.pageImagePath),
      slicePath: clearSlicePath ? null : (slicePath ?? this.slicePath),
      sliceWidth: sliceWidth ?? this.sliceWidth,
      sliceHeight: sliceHeight ?? this.sliceHeight,
      ocrRaw: clearOcrRaw ? null : (ocrRaw ?? this.ocrRaw),
      ocrStem: clearOcrStem ? null : (ocrStem ?? this.ocrStem),
      ocrSplitStatus: ocrSplitStatus ?? this.ocrSplitStatus,
      ocrManualEdited: ocrManualEdited ?? this.ocrManualEdited,
      contentVersion: contentVersion ?? this.contentVersion,
      questionType:
          clearQuestionType ? null : (questionType ?? this.questionType),
      questionTypeSource: questionTypeSource ?? this.questionTypeSource,
      questionBackgroundTags:
          questionBackgroundTags ?? this.questionBackgroundTags,
      questionBackgroundTagsSource:
          questionBackgroundTagsSource ?? this.questionBackgroundTagsSource,
      ocrFigures: ocrFigures ?? this.ocrFigures,
      correctOption:
          clearCorrectOption ? null : (correctOption ?? this.correctOption),
      optionLabels:
          clearOptionLabels ? null : (optionLabels ?? this.optionLabels),
      optionLabelsConfirmed:
          optionLabelsConfirmed ?? this.optionLabelsConfirmed,
      answerVersion: answerVersion ?? this.answerVersion,
      answerPendingRecheck: answerPendingRecheck ?? this.answerPendingRecheck,
      answerReconfirmed: answerReconfirmed ?? this.answerReconfirmed,
      optionLabelsJustConfirmed:
          optionLabelsJustConfirmed ?? this.optionLabelsJustConfirmed,
    );
  }
}

/// 十三批 M2：题干切分状态（存 questions.ocr_split_status，TEXT）。
/// 取值是中文原文（GPT 评审 §1.5 + D-106），不是英文枚举名。
/// 默认 [unsegmented]：OCR 还没跑、或没选项标记整段当题干时都是它。
class OcrSplitStatus {
  static const String unsegmented = '未切分';
  static const String autoSegmented = '自动切分';
  static const String ambiguous = '存在歧义';
  static const String manualAdjusted = '人工调整';

  static const Set<String> values = {
    unsegmented,
    autoSegmented,
    ambiguous,
    manualAdjusted,
  };
}

/// 收集任务：任务名 = 文件名 + 页 + 题号，不可改名。
enum CollectStatus {
  queued,
  importing,
  needBox,
  boxing,
  pendingOrganize,
  failed,
  done
}

extension CollectStatusLabel on CollectStatus {
  String get label => switch (this) {
        CollectStatus.queued => '排队中',
        CollectStatus.importing => '导入中',
        CollectStatus.needBox => '待框选',
        CollectStatus.boxing => '修框中',
        CollectStatus.pendingOrganize => '待整理',
        CollectStatus.failed => '导入失败',
        CollectStatus.done => '已整理',
      };
}

class CollectTask {
  CollectTask({
    required this.id,
    required this.name,
    required this.fileName,
    required this.subjectId,
    this.status = CollectStatus.queued,
    this.progress = 0,
    this.pageCount = 1,
    this.page = 1,
    this.error,
    this.questionId,
    this.createdAt,
    // §1.2(b)：sourcePath 是库内副本路径（fileName 只做显示名）；
    // pageRotations 是草稿修框的按页旋转角度（页 → 角度，见 §1.6.1）。
    this.sourcePath = '',
    this.pageRotations = const {},
    // 十二批 D-91：导入时存进来的原文件 SHA-256；旧行为 null。
    this.sourceHash,
  });
  final String id;
  final String name;
  final String fileName;
  final String subjectId;
  CollectStatus status;
  int progress; // 0-100 百分比
  final int pageCount;
  final int page;
  final String? error;
  final String? questionId; // 修框确认后产出的题目 id（一对一）
  /// 任务创建时间（§4.3：导入队列按它排序；UPDATE 不改它）。
  /// 旧行 / 旧备份里没有时为 null。
  final DateTime? createdAt;
  /// §1.2(b)：导入时复制进库的库内副本路径（相对数据目录）。
  final String sourcePath;
  /// §1.6.1：草稿修框的按页旋转角度（页 → 角度，如 {1: 90}）。
  final Map<int, int> pageRotations;
  /// 十二批 D-91：导入时存进来的原文件 SHA-256（见
  /// ImportService.contentHashOfFile）。重试时重算库内原图哈希比对；
  /// 旧行（v2 备份恢复、v2 库迁移而来）为 null，无基线可比。
  final String? sourceHash;
}

/// 十三批 M2：OCR 任务状态（存 ocr_jobs.status，TEXT，存枚举名）。
/// pending 待处理 / running 进行中 / completed 已完成 / failed 失败。
enum OcrJobStatus { pending, running, completed, failed }

extension OcrJobStatusLabel on OcrJobStatus {
  String get label => switch (this) {
    OcrJobStatus.pending => '待处理',
    OcrJobStatus.running => '进行中',
    OcrJobStatus.completed => '已完成',
    OcrJobStatus.failed => '失败',
  };
}

/// 十三批 M2：OCR 任务（ocr_jobs 表的一行，GPT 评审 §2.2 字段表）。
/// 队列 worker（M3）按它领任务、写结果；本文件只定义类型，不含队列逻辑。
/// 时间全是毫秒时间戳对应的 DateTime（与 Question.createdAt 同口径）：
/// availableAt 下次允许重试的时间（退避到期点；null = 立即可跑）；
/// startedAt 本次开始处理时间；leaseUntil worker 租约到期时间
///（启动时只回收租约已过期的 running 任务）；completedAt 完成时间
///（成功或失败终态都填，pending/running 为 null）。
/// inputHash 是本次识别用的切片 SHA-256：任务完成时须重算切片哈希比对，
/// 不一致不自动应用结果（旧切片结果不得写入新切片对应的题）。
/// lastErrorCode 是错误类型（如 api_key_missing / timeout / http_429，
/// 具体码表由 M3 定）；lastErrorMessage 是最近一次错误信息。
class OcrJob {
  OcrJob({
    required this.id,
    required this.questionId,
    this.cropPath,
    this.inputHash,
    this.status = OcrJobStatus.pending,
    this.attemptCount = 0,
    this.availableAt,
    this.startedAt,
    this.leaseUntil,
    this.leaseToken,
    this.lastErrorCode,
    this.lastErrorMessage,
    required this.createdAt,
    required this.updatedAt,
    this.completedAt,
  });

  final String id;
  final String questionId;

  /// 本次识别使用的切片路径（相对数据目录，imports/ 或 slices/ 下，
  /// 与 questions.slicePath 同口径；备份校验按该口径拦非法路径）。
  final String? cropPath;
  final String? inputHash;
  final OcrJobStatus status;

  /// 实际发起请求的次数（首次请求算 1；“重试 3 次”= 最多 4 次请求）。
  final int attemptCount;
  final DateTime? availableAt;
  final DateTime? startedAt;
  final DateTime? leaseUntil;

  /// 十三批 P1-1：租约 token（ocr_jobs.lease_token）。claim 时生成唯一
  /// 值并存入；complete / fail / retry / markAttempt 时须与当前持有者
  /// 一致才写库——任务被回收重领后，旧 worker 的任何写操作都不生效。
  /// pending / failed / completed 行恒为 null（不持有租约）。
  final String? leaseToken;

  final String? lastErrorCode;
  final String? lastErrorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;

  OcrJob copyWith({
    String? cropPath,
    String? inputHash,
    OcrJobStatus? status,
    int? attemptCount,
    DateTime? availableAt,
    DateTime? startedAt,
    DateTime? leaseUntil,
    String? leaseToken,
    String? lastErrorCode,
    String? lastErrorMessage,
    DateTime? updatedAt,
    DateTime? completedAt,
    bool clearAvailableAt = false,
    bool clearStartedAt = false,
    bool clearLeaseUntil = false,
    bool clearLeaseToken = false,
    bool clearCompletedAt = false,
  }) {
    return OcrJob(
      id: id,
      questionId: questionId,
      cropPath: cropPath ?? this.cropPath,
      inputHash: inputHash ?? this.inputHash,
      status: status ?? this.status,
      attemptCount: attemptCount ?? this.attemptCount,
      availableAt: clearAvailableAt ? null : (availableAt ?? this.availableAt),
      startedAt: clearStartedAt ? null : (startedAt ?? this.startedAt),
      leaseUntil: clearLeaseUntil ? null : (leaseUntil ?? this.leaseUntil),
      leaseToken: clearLeaseToken ? null : (leaseToken ?? this.leaseToken),
      lastErrorCode: lastErrorCode ?? this.lastErrorCode,
      lastErrorMessage: lastErrorMessage ?? this.lastErrorMessage,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      completedAt: clearCompletedAt ? null : (completedAt ?? this.completedAt),
    );
  }
}

/// 题级框：layer 1 整题框（完整题目就是最小单位，永不拆题）。
/// §1.2(c)：表里有的字段模型里也要有（扩展模型，不另建 StoredQuestionBox）。
/// 编辑器内新建的框只填 id/layer/type/x/y/w/h，其余为 NULL/默认值：
/// confidence 只有 YOLO 框有值（手画框为 NULL），origin 默认 'manual'，
/// collectTaskId 是修框阶段的草稿归属（确认后只保留 questionId），
/// parentBoxId 保留给旧数据行（新框恒为 NULL），page 默认 1。
class QuestionBox {
  const QuestionBox({
    required this.id,
    required this.layer,
    required this.type, // question；旧行可能取历史值（表 CHECK 约束为准）
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.confidence,
    this.origin = 'manual',
    this.parentBoxId,
    this.page = 1,
    this.collectTaskId,
    this.questionId,
    this.updatedAt,
  });
  final String id;
  final int layer;
  final String type;
  final double x, y, w, h; // 相对页面的 0..1 坐标，钳制在页面范围内
  final double? confidence; // YOLO 置信度 0..1；手画框为 NULL
  final String origin; // 'yolo' / 'manual'
  final String? parentBoxId;
  final int page;
  final String? collectTaskId;
  final String? questionId;
  final DateTime? updatedAt;

  QuestionBox copyWith({
    String? id,
    int? layer,
    String? type,
    double? x,
    double? y,
    double? w,
    double? h,
    double? confidence,
    String? origin,
    String? parentBoxId,
    int? page,
    String? collectTaskId,
    String? questionId,
    DateTime? updatedAt,
    bool clearConfidence = false,
    bool clearParentBoxId = false,
    bool clearCollectTaskId = false,
    bool clearQuestionId = false,
  }) =>
      QuestionBox(
        id: id ?? this.id,
        layer: layer ?? this.layer,
        type: type ?? this.type,
        x: x ?? this.x,
        y: y ?? this.y,
        w: w ?? this.w,
        h: h ?? this.h,
        confidence:
            clearConfidence ? null : (confidence ?? this.confidence),
        origin: origin ?? this.origin,
        parentBoxId:
            clearParentBoxId ? null : (parentBoxId ?? this.parentBoxId),
        page: page ?? this.page,
        collectTaskId:
            clearCollectTaskId ? null : (collectTaskId ?? this.collectTaskId),
        questionId:
            clearQuestionId ? null : (questionId ?? this.questionId),
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

/// 设置（settings 表 key/value 存取，见 AppSettings.defaults）。
class AppSettings {
  const AppSettings({
    this.themeMode = 'system', // system / light / dark
    this.fontSize = 'standard', // standard / large / extraLarge
    this.greeting = '今天也要加油呀',
    this.recheckIntervalDays = 7, // 3 / 7 / 14
    this.cureChecks = 2, // 1 / 2 / 3
    this.causesPerSession = 0, // 5 / 10 / 0=不限
    this.skipLimit = 2, // 1 / 2
    this.redoAnswerHidden = true,
    this.notifyEnabled = true,
    this.notifyTime = '20:00',
    this.reviewSort = 'joinTime', // joinTime / subject
    this.wrongbookView = 'large', // large / compact
    this.pageSize = 10, // 10 / 20 / 30 / 40 / 50
    this.wrongbookSort = 'new', // new / old / subj-asc / subj-desc /
    // status-asc / status-desc（与错题本列表下拉六项一致；旧值 'subject'
    // 读库 / 写入时由 normalizeWrongbookSort 归一为 subj-asc）
    this.startupPage = 'home', // home / last
  });

  final String themeMode;
  final String fontSize;
  final String greeting;
  final int recheckIntervalDays;
  final int cureChecks;
  final int causesPerSession;
  final int skipLimit;
  final bool redoAnswerHidden;
  final bool notifyEnabled;
  final String notifyTime;
  final String reviewSort;
  final String wrongbookView;
  final int pageSize;
  final String wrongbookSort;
  final String startupPage;

  static const defaults = AppSettings();

  /// 错题本列表下拉的合法排序值（wrongbook_list.dart 六项）。
  static const wrongbookSortValues = {
    'new',
    'old',
    'subj-asc',
    'subj-desc',
    'status-asc',
    'status-desc',
  };

  /// 归一错题本默认排序：旧值 'subject'（SR-P0-2 之前设置页的选项，
  /// 列表下拉从无此项）按原意归为 'subj-asc'；其它未知值回落到 'new'，
  /// 绝不把非法值喂给 DropdownButton / QmSegmented。
  static String normalizeWrongbookSort(String value) => switch (value) {
        'subject' => 'subj-asc',
        _ when wrongbookSortValues.contains(value) => value,
        _ => 'new',
      };

  Map<String, String> toMap() => {
        'themeMode': themeMode,
        'fontSize': fontSize,
        'greeting': greeting,
        'recheckIntervalDays': '$recheckIntervalDays',
        'cureChecks': '$cureChecks',
        'causesPerSession': '$causesPerSession',
        'skipLimit': '$skipLimit',
        'redoAnswerHidden': redoAnswerHidden ? '1' : '0',
        'notifyEnabled': notifyEnabled ? '1' : '0',
        'notifyTime': notifyTime,
        'reviewSort': reviewSort,
        'wrongbookView': wrongbookView,
        'pageSize': '$pageSize',
        'wrongbookSort': wrongbookSort,
        'startupPage': startupPage,
      };

  static AppSettings fromMap(Map<String, String> m) {
    int parseInt(String k, int d) => int.tryParse(m[k] ?? '') ?? d;
    bool parseBool(String k, bool d) =>
        m[k] == null ? d : m[k] == '1' || m[k] == 'true';
    return AppSettings(
      themeMode: m['themeMode'] ?? 'system',
      fontSize: m['fontSize'] ?? 'standard',
      greeting: m['greeting'] ?? '今天也要加油呀',
      recheckIntervalDays: parseInt('recheckIntervalDays', 7),
      cureChecks: parseInt('cureChecks', 2),
      causesPerSession: parseInt('causesPerSession', 0),
      skipLimit: parseInt('skipLimit', 2),
      redoAnswerHidden: parseBool('redoAnswerHidden', true),
      notifyEnabled: parseBool('notifyEnabled', true),
      notifyTime: m['notifyTime'] ?? '20:00',
      reviewSort: m['reviewSort'] ?? 'joinTime',
      wrongbookView: m['wrongbookView'] ?? 'large',
      pageSize: parseInt('pageSize', 10),
      wrongbookSort: normalizeWrongbookSort(m['wrongbookSort'] ?? 'new'),
      startupPage: m['startupPage'] ?? 'home',
    );
  }

  AppSettings copyWith({
    String? themeMode,
    String? fontSize,
    String? greeting,
    int? recheckIntervalDays,
    int? cureChecks,
    int? causesPerSession,
    int? skipLimit,
    bool? redoAnswerHidden,
    bool? notifyEnabled,
    String? notifyTime,
    String? reviewSort,
    String? wrongbookView,
    int? pageSize,
    String? wrongbookSort,
    String? startupPage,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        fontSize: fontSize ?? this.fontSize,
        greeting: greeting ?? this.greeting,
        recheckIntervalDays: recheckIntervalDays ?? this.recheckIntervalDays,
        cureChecks: cureChecks ?? this.cureChecks,
        causesPerSession: causesPerSession ?? this.causesPerSession,
        skipLimit: skipLimit ?? this.skipLimit,
        redoAnswerHidden: redoAnswerHidden ?? this.redoAnswerHidden,
        notifyEnabled: notifyEnabled ?? this.notifyEnabled,
        notifyTime: notifyTime ?? this.notifyTime,
        reviewSort: reviewSort ?? this.reviewSort,
        wrongbookView: wrongbookView ?? this.wrongbookView,
        pageSize: pageSize ?? this.pageSize,
        wrongbookSort: wrongbookSort == null
            ? this.wrongbookSort
            : normalizeWrongbookSort(wrongbookSort),
        startupPage: startupPage ?? this.startupPage,
      );

  /// 字体缩放倍率（D4）：标准 1.00 / 大 1.15 / 特大 1.30，标题、按钮、
  /// 正文一起放。唯一映射入口（与 lib/theme/design_tokens.dart 的
  /// FontScale.factorFor 保持一致）；不要在别处再写 1.12 / 1.25 旧值。
  /// 只改缩放因子映射，不改设置存储结构（fontSize 仍是
  /// standard / large / extraLarge 三档字符串）与业务语义。
  double get fontScale => FontScale.factorFor(fontSize);
}
