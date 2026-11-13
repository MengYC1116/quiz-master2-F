/// B4.1：复查提醒（应用内、进入应用时一次）。
///
/// 触发条件（四条全满足才弹）：
/// 1. 通知开关开着（设置 #20 `notifyEnabled`）；
/// 2. 有错因到了复查时间（已解决且复查日 ≤ 今天，见
///    `CauseRecord.isRecheckDue`；计数见 `QuestionRepository
///    .recheckDueCauseCount`）；
/// 3. 已到当日提醒时间（设置 #21 `notifyTime`，默认 20:00）——
///    进应用时若还没到点，不提醒，等下次进应用时再判断；
///    到点指 `now >= 今天 notifyTime`（含整点那一刻）；
/// 4. 今天还没提醒过（一天一次；提醒过的日期存在 settings 表
///    key `lastRecheckReminderDate`，见 database.dart，与 B3 的
///    lastRoute 同一做法，不新开表）。
///
/// 只在应用启动时判断一次（app.dart `_loadSettings` 后），不随切页
/// 重复弹；不接系统通知、不引通知插件。`notifyTime` 写坏了
/// （如 'abc'）按默认 20:00 算，不崩。
library;

/// 今天的日期串（`yyyy-MM-dd`），一天一次的比对键。
String recheckReminderDateString(DateTime now) =>
    '${now.year.toString().padLeft(4, '0')}-'
    '${now.month.toString().padLeft(2, '0')}-'
    '${now.day.toString().padLeft(2, '0')}';

/// 解析提醒时间 `HH:MM`，写坏了回落 20:00。
({int hour, int minute}) parseNotifyTime(String notifyTime) {
  final parts = notifyTime.split(':');
  final hour = int.tryParse(parts.elementAtOrNull(0) ?? '');
  final minute = int.tryParse(parts.elementAtOrNull(1) ?? '');
  if (hour == null || minute == null || hour < 0 || hour > 23 ||
      minute < 0 || minute > 59) {
    return (hour: 20, minute: 0);
  }
  return (hour: hour, minute: minute);
}

/// 四条全满足才返回 true。纯函数，便于单测。
bool shouldShowRecheckReminder({
  required bool notifyEnabled,
  required String notifyTime,
  required int dueRecheckCount,
  required DateTime now,
  String? lastRemindedDate,
}) {
  if (!notifyEnabled) return false;
  if (dueRecheckCount <= 0) return false;
  if (lastRemindedDate != null &&
      lastRemindedDate == recheckReminderDateString(now)) {
    return false;
  }
  final t = parseNotifyTime(notifyTime);
  final dueAt = DateTime(now.year, now.month, now.day, t.hour, t.minute);
  return !now.isBefore(dueAt);
}
