import 'package:flutter/material.dart';

/// 学科：初始三科，顺序固定 数学 / 英语 / 政治（大学阶段）。
class Subject {
  const Subject({
    required this.id,
    required this.name,
    required this.color,
    required this.icon,
  });
  final String id;
  final String name;
  final Color color;
  final String icon; // 单字图标，如 数 / 英 / 政

  static const math = Subject(
      id: 'math', name: '数学', color: Color(0xFF2F7CF6), icon: '数');
  static const english = Subject(
      id: 'english', name: '英语', color: Color(0xFF1F9D66), icon: '英');
  static const politics = Subject(
      id: 'politics', name: '政治', color: Color(0xFFE0524D), icon: '政');
  static const all = [math, english, politics];
  static Subject byId(String id) =>
      all.firstWhere((s) => s.id == id, orElse: () => math);
}

/// 复习状态。已掌握默认不在错题本显示。
enum ReviewStatus { inReview, mastered }

extension ReviewStatusLabel on ReviewStatus {
  String get label => this == ReviewStatus.mastered ? '已掌握' : '复习中';
}

/// 错误类型：固定枚举 + 自定义（自定义只跟本题，下次可选，不进全局枚举）。
class ErrorTypes {
  static const fixed = ['审题失误', '概念不清', '计算错误', '方法不会', '其他'];
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
    this.reviewStatus = ReviewStatus.inReview,
    this.reviewCount = 0,
    this.isOrganized = false,
    this.isDemo = false,
    this.nextReview,
    this.overdueDays = 0,
    this.isFavorite = false,
    this.isArchived = false,
    required this.createdAt,
    // 整题图切片的演示形态：chart / timeline / material / function / limit
    this.sliceKind = 'material',
    // 题干切片文字（演示用；真实数据是图片切片，无 OCR）
    this.sliceText = '',
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
  final ReviewStatus reviewStatus;
  final int reviewCount;
  /// 是否已在整理工作台确认过。确认后首次复习为次日；待整理队列只看
  /// 此标记，不看 reviewCount（确认不改 reviewCount，旧口径会把已确认
  /// 的题在重进页面后又放回队列）。
  final bool isOrganized;
  /// 演示题标记（D-11）：首次建库写入的 9 道演示题为 true，真实导入的题
  /// 为 false；“清空演示数据”只删 is_demo = 1 的题。
  final bool isDemo;
  final DateTime? nextReview;
  final int overdueDays;
  final bool isFavorite;
  final bool isArchived;
  final DateTime createdAt;
  final String sliceKind;
  final String sliceText;

  bool get isDueToday =>
      reviewStatus == ReviewStatus.inReview &&
      (nextReview == null ||
          !nextReview!.isAfter(DateTime.now().add(const Duration(days: 1))));
  bool get isOverdue => overdueDays > 0;

  /// 下次复习文案：下次复习 11-12 / 逾期 N 天 / 今天到期。
  String get nextReviewLabel {
    if (overdueDays > 0) return '逾期 $overdueDays 天';
    if (nextReview == null) return '待补充';
    final now = DateTime.now();
    if (nextReview!.year == now.year &&
        nextReview!.month == now.month &&
        nextReview!.day == now.day) {
      return '下次复习 今天';
    }
    return '下次复习 ${nextReview!.month}-${nextReview!.day}';
  }

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
    ReviewStatus? reviewStatus,
    int? reviewCount,
    bool? isOrganized,
    bool? isDemo,
    DateTime? nextReview,
    int? overdueDays,
    bool? isFavorite,
    bool? isArchived,
  }) {
    return Question(
      id: id,
      title: title,
      subjectId: subjectId,
      folderIds: folderIds ?? this.folderIds,
      examId: examId ?? this.examId,
      knowledgePointIds: knowledgePointIds ?? this.knowledgePointIds,
      errorTypes: errorTypes ?? this.errorTypes,
      customErrorTypes: customErrorTypes ?? this.customErrorTypes,
      tags: tags ?? this.tags,
      answer: answer ?? this.answer,
      explanation: explanation ?? this.explanation,
      notes: notes ?? this.notes,
      reviewStatus: reviewStatus ?? this.reviewStatus,
      reviewCount: reviewCount ?? this.reviewCount,
      isOrganized: isOrganized ?? this.isOrganized,
      isDemo: isDemo ?? this.isDemo,
      nextReview: nextReview ?? this.nextReview,
      overdueDays: overdueDays ?? this.overdueDays,
      isFavorite: isFavorite ?? this.isFavorite,
      isArchived: isArchived ?? this.isArchived,
      createdAt: createdAt,
      sliceKind: sliceKind,
      sliceText: sliceText,
    );
  }
}

/// 收集任务：任务名 = 文件名 + 页 + 题号，不可改名。
enum CollectStatus { queued, importing, needBox, boxing, pendingOrganize, failed, done }

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
}

/// 两层框：layer 1 整题框，layer 2 题干 / 选项 / 配图（只做辅助区，永不拆题）。
class QuestionBox {
  const QuestionBox({
    required this.id,
    required this.layer,
    required this.type, // question / stem / option / figure
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });
  final String id;
  final int layer;
  final String type;
  final double x, y, w, h; // 相对页面的 0..1 坐标，钳制在页面范围内
}
