// B11-9 考试倒计时：考试事件（与试卷完全脱钩的独立数据）。
//
// 考试事件只存自定义名称 + 考试日期，不选试卷、不关联试卷、不读任何
// 试卷数据。`Exam`（试卷实体，lib/models/models.dart）与它没有任何
// 关系：不同表/不同存储、不同 id 前缀、没有任何外键或引用。
//
// 口径（写死，不含时分秒，按日历日算）：
// - [daysUntilExam]：N = 考试日期 - 今天（两者都先去掉时分秒）。
//   今天 = 0，明天 = 1，昨天 = -1；同一天内任何时刻结果相同。
// - [nearestExamEvent]：多场考试取“最近一场”——未过期的（含今天）
//   里取 N 最小的一场；全部过期时取最近过期那场（N 最大，即离今天
//   最近的过去日期）；无考试返回 null。
// - [examCountdownText]：N > 0 → “距离 <名称> 还有 N 天”；
//   N = 0 → “今天 <名称>”；N < 0 → “<名称> 已考完”。
// - [isExamCountdownNear]：临近标红阈值——0 <= N <= 7（7 天 / 3 天 /
//   1 天都在内）；过期（N < 0）与 8 天以上不标红。
// - 日期只存年月日（`yyyy-MM-dd` 字符串），不存时分秒、不存时区。

/// 一场考试：自定义名称 + 考试日期（仅日期，不含时分秒）。
class ExamEvent {
  const ExamEvent({
    required this.id,
    required this.name,
    required this.date,
  });

  /// id 前缀 `exam-event-`，与试卷 `exam-` 区分开。
  final String id;

  /// 用户自己填的考试名，如“期末考试”。
  final String name;

  /// 考试日期（仅年月日；构造时若带时分秒会被 [dateOnly] 归一化）。
  final DateTime date;

  ExamEvent copyWith({String? id, String? name, DateTime? date}) =>
      ExamEvent(
        id: id ?? this.id,
        name: name ?? this.name,
        date: date == null ? this.date : dateOnly(date),
      );

  /// 存 settings 表 JSON 用：日期只写 `yyyy-MM-dd`。
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'date': formatExamEventDate(date),
      };

  /// 读 settings 表 JSON：字段缺失/类型不对/日期非法时返回 null
  ///（调用方跳过该行，不让一行坏数据拖垮整个列表）。
  static ExamEvent? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final name = value['name'];
    final date = value['date'];
    if (id is! String || id.isEmpty) return null;
    if (name is! String || name.isEmpty) return null;
    if (date is! String) return null;
    final parsed = DateTime.tryParse(date);
    if (parsed == null) return null;
    return ExamEvent(id: id, name: name, date: dateOnly(parsed));
  }
}

/// 去掉时分秒，只留年月日（本地时区）。
DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// `yyyy-MM-dd`（月、日补零，与设置页/学科页的日期文案同一格式）。
String formatExamEventDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}'
    '-${d.day.toString().padLeft(2, '0')}';

/// 倒计时天数：N = 考试日期 - 今天，按日历日算，不含时分秒。
/// [today] 默认现在；测试可传入固定日期。
int daysUntilExam(DateTime examDate, [DateTime? today]) {
  final now = today ?? DateTime.now();
  return dateOnly(examDate).difference(dateOnly(now)).inDays;
}

/// 临近标红：0 <= N <= 7（7 天 / 3 天 / 1 天都在内；过期与 8 天以上不红）。
bool isExamCountdownNear(int daysUntil) =>
    daysUntil >= 0 && daysUntil <= 7;

/// 多场考试取“最近一场”：未过期的（含今天）里取 N 最小的一场；
/// 全部过期时取最近过期那场；无考试返回 null。
/// N 相同（如同一天两场）时取列表里先出现的那场。
ExamEvent? nearestExamEvent(List<ExamEvent> events, [DateTime? today]) {
  if (events.isEmpty) return null;
  final now = today ?? DateTime.now();
  ExamEvent? best;
  var bestDays = 0;
  for (final e in events) {
    final days = daysUntilExam(e.date, now);
    if (best == null) {
      best = e;
      bestDays = days;
      continue;
    }
    // 未过期的优先于过期的；同类里取离今天最近的（未过期取 N 最小，
    // 过期取 N 最大，即最近过期那场）。
    if (bestDays < 0 && days >= 0) {
      best = e;
      bestDays = days;
    } else if (bestDays >= 0 && days >= 0 && days < bestDays) {
      best = e;
      bestDays = days;
    } else if (bestDays < 0 && days < 0 && days > bestDays) {
      best = e;
      bestDays = days;
    }
  }
  return best;
}

/// 首页倒计时文案：N > 0 → “距离 <名称> 还有 N 天”；
/// N = 0 → “今天 <名称>”；N < 0 → “<名称> 已考完”。
String examCountdownText(ExamEvent event, [DateTime? today]) {
  final days = daysUntilExam(event.date, today);
  if (days > 0) return '距离 ${event.name} 还有 $days 天';
  if (days == 0) return '今天 ${event.name}';
  return '${event.name} 已考完';
}
