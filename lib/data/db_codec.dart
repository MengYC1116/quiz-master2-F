// B4：database.dart 拆分——JSON 编解码：encode/decodeStringList /
// encode/decodeQueue / encode/decodeRemedyList。
// 与 database.dart 同一库（part of），共享库私有成员；纯重构，行为不变。
// B2 集成：旧 Map 行映射 _toRow / _fromRow / _causeFromRow /
// _causeRecordToRow / _collectTaskToRow 已删——questions /
// cause_records / collect_tasks 的读写已全部走 Drift 类型化
//（行映射见 db_questions.dart 的 _questionFromDb /
// _causeRecordFromDb 与 Companion，框/任务见 db_collect.dart）。
// encode*/decode* 的 Impl 保留：AppDatabase 的同名公开静态方法仍
// 被测试调用（p2_json_fields_test、b5_p2_data_test），按任务要求留着。

part of 'database.dart';

/// §3.2：多值字段编解码收口（全部 11 处读写点统一调这里，
/// 业务代码里不许再出现裸 `join(',')` / `split(',')`）：
/// - [AppDatabase.encodeStringList]/[AppDatabase.decodeStringList]：folder_ids /
///   knowledge_ids / error_types / custom_error_types / tags；
/// - [AppDatabase.encodeRemedyList]/[AppDatabase.decodeRemedyList]：remedy_history
///   （与字符串列表同构，单列一对函数是为将来补救条目变对象时只改一处）；
/// - [AppDatabase.encodeQueue]/[AppDatabase.decodeQueue]：review_state.queue（对象数组，
///   见 §3.4 的 ReviewQueueItem）。
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
