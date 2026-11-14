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
    required this.questionId,
    required this.cause,
    required this.subjectId,
    this.status = CauseStatus.pending,
    this.solvedCount = 0,
    this.lastCheck,
    this.recheckDate,
    this.remedyHistory = const [],
    required this.joinedAt,
  });

  final String questionId;
  final String cause;
  final String subjectId;
  final CauseStatus status;
  final int solvedCount; // 同一错因同一道题自查“已解决”的累计次数
  final DateTime? lastCheck;
  final DateTime? recheckDate;
  final List<String> remedyHistory; // 每次写补救的内容（带日期），新→旧
  final DateTime joinedAt; // 加入复习的时间，列表按它排

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
    CauseStatus? status,
    int? solvedCount,
    DateTime? lastCheck,
    DateTime? recheckDate,
    List<String>? remedyHistory,
    DateTime? joinedAt,
    bool clearRecheckDate = false,
  }) {
    return CauseRecord(
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
class ReviewSessionState {
  const ReviewSessionState({
    required this.queue,
    required this.position,
    required this.updatedAt,
  });
  // 队列项按解决顺序排（ReviewQueueItem，不再拼 "qid|cause" 字符串）。
  final List<ReviewQueueItem> queue;
  final int position;
  final DateTime updatedAt;
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
  final bool isDemo; // 演示题标记，“清空演示数据”只删 is_demo = 1 的题
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

  /// 全部错因（固定枚举 + 自定义）。
  List<String> get allCauses => [...errorTypes, ...customErrorTypes];

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
    // 传 null 表示“保持原值”；要把字段清空时用这些标志（整理/详情页
    // 把答案、解析、笔记清空后保存必须真正清掉，不能留旧值）。
    bool clearExamId = false,
    bool clearAnswer = false,
    bool clearExplanation = false,
    bool clearNotes = false,
    bool clearSourcePath = false,
    bool clearPageImagePath = false,
    bool clearSlicePath = false,
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
    );
  }
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
}

/// 两层框：layer 1 整题框，layer 2 题干 / 选项 / 配图（只做辅助区，永不拆题）。
/// §1.2(c)：表里有的字段模型里也要有（扩展模型，不另建 StoredQuestionBox）。
/// 编辑器内新建的框只填 id/layer/type/x/y/w/h，其余为 NULL/默认值：
/// confidence 只有 YOLO 框有值（手画框为 NULL），origin 默认 'manual'，
/// collectTaskId 是修框阶段的草稿归属（确认后只保留 questionId），
/// parentBoxId 是第 2 层框的父框（第 1 层框为 NULL），page 默认 1。
class QuestionBox {
  const QuestionBox({
    required this.id,
    required this.layer,
    required this.type, // question / stem / option / figure
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
    this.wrongbookSort = 'new', // new / old / subject
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
      wrongbookSort: m['wrongbookSort'] ?? 'new',
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
        wrongbookSort: wrongbookSort ?? this.wrongbookSort,
        startupPage: startupPage ?? this.startupPage,
      );

  /// 字体缩放倍率（D4）：标准 1.00 / 大 1.15 / 特大 1.30，标题、按钮、
  /// 正文一起放。唯一映射入口（与 lib/theme/design_tokens.dart 的
  /// FontScale.factorFor 保持一致）；不要在别处再写 1.12 / 1.25 旧值。
  /// 只改缩放因子映射，不改设置存储结构（fontSize 仍是
  /// standard / large / extraLarge 三档字符串）与业务语义。
  double get fontScale => FontScale.factorFor(fontSize);
}
