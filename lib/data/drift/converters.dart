// ARCH-PLAN-B 第 2 阶段：Drift TypeConverter（JSON 文本 ↔ Dart 业务类型）。
//
// 与 lib/data/db_codec.dart 的编解码约定逐字一致（空串/NULL/非法 JSON -> []；
// 编码空列表写 '[]'；queue 对象数组键为 'q'/'c'；rotations 键为字符串页码）。
// 注意：db_codec.dart 是 `part of 'database.dart'`，其 Impl 函数是库私有的，
// 本文件不能直接调；这里按尖峰（B-SPIKE-REPORT.md §3，已验证存储表示逐字节
// 一致）的做法把同一逻辑写成本文件内的转换器，约定源头仍是 db_codec.dart。
// 若 db_codec.dart 的约定改了，这里必须同步改。

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../models/models.dart';

/// JSON 文本 ↔ `List<String>`（questions 多值字段、remedy_history）。
class StringListConverter extends TypeConverter<List<String>, String> {
  const StringListConverter();

  @override
  List<String> fromSql(String fromDb) {
    if (fromDb.isEmpty) return const [];
    try {
      final decoded = jsonDecode(fromDb);
      if (decoded is List) return decoded.whereType<String>().toList();
    } catch (_) {}
    return const [];
  }

  @override
  String toSql(List<String> value) => jsonEncode(value);
}

/// JSON 文本 ↔ `List<String>?`（十四批 M1：questions.option_labels，
/// NULL = 未确认；空串/非法 JSON -> []，与 [StringListConverter] 同口径）。
class NullableStringListConverter
    extends TypeConverter<List<String>?, String?> {
  const NullableStringListConverter();

  @override
  List<String>? fromSql(String? fromDb) {
    if (fromDb == null) return null;
    if (fromDb.isEmpty) return const [];
    try {
      final decoded = jsonDecode(fromDb);
      if (decoded is List) return decoded.whereType<String>().toList();
    } catch (_) {}
    return const [];
  }

  @override
  String? toSql(List<String>? value) =>
      value == null ? null : jsonEncode(value);
}

/// JSON 对象数组 ↔ `List<ReviewQueueItem>`（review_state.queue）。
class QueueConverter extends TypeConverter<List<ReviewQueueItem>, String> {
  const QueueConverter();

  @override
  List<ReviewQueueItem> fromSql(String fromDb) {
    if (fromDb.isEmpty) return const [];
    try {
      final decoded = jsonDecode(fromDb);
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

  @override
  String toSql(List<ReviewQueueItem> value) => jsonEncode([
    for (final item in value) {'q': item.questionId, 'c': item.cause},
  ]);
}

/// JSON 文本 {"1": 90} ↔ `Map<int, int>`（collect_tasks.page_rotations）。
class RotationsConverter extends TypeConverter<Map<int, int>, String> {
  const RotationsConverter();

  @override
  Map<int, int> fromSql(String fromDb) {
    if (fromDb.isEmpty) return const {};
    try {
      final decoded = jsonDecode(fromDb);
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

  @override
  String toSql(Map<int, int> value) => jsonEncode({
    for (final e in value.entries) '${e.key}': e.value,
  });
}
