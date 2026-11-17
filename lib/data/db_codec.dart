// B4：database.dart 拆分——JSON 编解码：encode/decodeStringList /
// encode/decodeQueue / encode/decodeRemedyList。
// 与 database.dart 同一库（part of），共享库私有成员；纯重构，行为不变。
// encode*/decode* 的 Impl 保留：AppDatabase 的同名公开静态方法仍
// 被测试调用（p2_json_fields_test、b5_p2_data_test）。

part of 'database.dart';

/// §3.2：多值字段编解码收口（全部 11 处读写点统一调这里，
/// 业务代码里不许再出现裸 `join(',')` / `split(',')`）：
/// - [AppDatabase.encodeStringList]/[AppDatabase.decodeStringList]：folder_ids /
///   knowledge_ids / error_types / custom_error_types / tags；
/// - [AppDatabase.encodeRemedyList]/[AppDatabase.decodeRemedyList]：remedy_history
///   （与字符串列表同构，单列一对函数是为将来补救条目变对象时只改一处）；
/// - [AppDatabase.encodeQueue]/[AppDatabase.decodeQueue]：review_state.queue（对象数组，
///   见 §3.4 的 ReviewQueueItem）。
/// - [AppDatabase.decodeRotations]：collect_tasks.page_rotations（`{"1": 90}`，
///   B3 补：备份恢复的类型化映射用；编码侧仍走 RotationsConverter，与
///   StringListConverter / QueueConverter 同逻辑——空串与 NULL 解码为 {}，
///   编码空 Map 写 '{}'）。
/// 空串 '' 与 NULL 统一解码为 []；编码空列表写 '[]'，不写 ''。
/// 读到非法值（不是 JSON 字符串数组）按空列表处理，不猜逗号拆分
/// （§3.3：没有老数据需要兼容，读侧只认 JSON）。
String encodeStringListImpl(List<String> values) => jsonEncode(values);

List<String> decodeStringListImpl(Object? value) {
  if (value == null) return const [];
  if (value is! String || value.isEmpty) return const [];
  try {
    final decoded = jsonDecode(value);
    if (decoded is List) {
      return decoded.whereType<String>().toList();
    }
  } catch (_) {}
  return const [];
}

String encodeRemedyListImpl(List<String> values) => jsonEncode(values);

List<String> decodeRemedyListImpl(Object? value) =>
    AppDatabase.decodeStringList(value);

String encodeQueueImpl(List<ReviewQueueItem> queue) => jsonEncode([
  for (final item in queue) {'q': item.questionId, 'c': item.cause},
]);

List<ReviewQueueItem> decodeQueueImpl(Object? value) {
  if (value == null) return const [];
  if (value is! String || value.isEmpty) return const [];
  try {
    final decoded = jsonDecode(value);
    if (decoded is List) {
      return [
        for (final e in decoded)
          if (e is Map && e['q'] is String && e['c'] is String)
            ReviewQueueItem(
              questionId: e['q'] as String,
              cause: e['c'] as String,
            ),
      ];
    }
  } catch (_) {}
  return const [];
}

/// B3：collect_tasks.page_rotations 解码（`{"1": 90}` ↔ `Map<int, int>`）。
/// 与 [RotationsConverter.fromSql] 同逻辑（空串/NULL/非法 JSON -> {}），
/// 供备份恢复的类型化映射用（db_backup.dart 的 `_backupInsertRowTyped`），
/// 与 decodeStringList / decodeQueue 同口径：读侧只认 JSON，不猜其它格式。
Map<int, int> decodeRotationsImpl(Object? value) {
  if (value == null) return const {};
  if (value is! String || value.isEmpty) return const {};
  try {
    final decoded = jsonDecode(value);
    if (decoded is Map) {
      return {
        for (final e in decoded.entries)
          if (int.tryParse('${e.key}') != null && e.value is num)
            int.parse('${e.key}'): (e.value as num).toInt(),
      };
    }
  } catch (_) {}
  return const {};
}
