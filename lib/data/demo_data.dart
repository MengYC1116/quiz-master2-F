import '../models/models.dart';

// SR-P2-13：demoQuestions() 已删除——新库从空开始、不预置演示题
// （§6 第 1 条），它没有任何生产调用方，只剩定义；且其中 4 道题
// 写了 reviewJoined: true 却没写 isOrganized: true，违反“未整理
// 的题没有加入复习入口”的模型，留着是误导。演示题的唯一合法来源
// 是 v1 老库（已整体删除，不迁移）；demoExams() /
// demoKnowledgePoints() 仍在 _seed 里用，保留。

/// 预置知识点树（大学层级）：学科 → 章节 → 知识点。
List<KnowledgePoint> demoKnowledgePoints() => const [
      KnowledgePoint(
          id: 'kp-math-limit',
          subjectId: 'math',
          chapter: '函数与极限',
          name: '函数极限'),
      KnowledgePoint(
          id: 'kp-math-derivative',
          subjectId: 'math',
          chapter: '导数与微分',
          name: '导数应用'),
      KnowledgePoint(
          id: 'kp-math-integral',
          subjectId: 'math',
          chapter: '定积分',
          name: '定积分应用'),
      KnowledgePoint(
          id: 'kp-eng-vocab',
          subjectId: 'english',
          chapter: '词汇',
          name: '学术词汇'),
      KnowledgePoint(
          id: 'kp-eng-reading',
          subjectId: 'english',
          chapter: '阅读',
          name: '长篇阅读'),
      KnowledgePoint(
          id: 'kp-eng-writing',
          subjectId: 'english',
          chapter: '写作',
          name: '图表作文'),
      KnowledgePoint(
          id: 'kp-pol-history',
          subjectId: 'politics',
          chapter: '史纲',
          name: '时间轴'),
      KnowledgePoint(
          id: 'kp-pol-marx',
          subjectId: 'politics',
          chapter: '马原',
          name: '矛盾观'),
    ];

List<Exam> demoExams() => [
      Exam(id: 'exam-math-mid', name: '高等数学期中试卷',
          date: DateTime(2026, 11, 3)),
      Exam(id: 'exam-eng-mid', name: '大学英语期中试卷',
          date: DateTime(2026, 11, 4)),
      Exam(id: 'exam-pol-mid', name: '大学思政期中试卷',
          date: DateTime(2026, 11, 5)),
    ];

/// 预置文件夹（每科一套）与标签。
const List<String> presetFolders = ['试卷', '平时作业', '模拟卷'];
const List<String> presetTags = ['易错', '常考', '需重做'];
