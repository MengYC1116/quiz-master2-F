// B4：database.dart 拆分——JSON 编解码与行映射：encode/decodeStringList / encode/decodeQueue / _toRow / _fromRow / _causeFromRow / _collectTaskFromRow / _questionBoxFromRow 等。
// 与 database.dart 同一库（part of），共享库私有成员；纯重构，行为不变。

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

Map<String, Object?> _toRow(Question q) => {
  'id': q.id,
  'title': q.title,
  'subject_id': q.subjectId,
  'folder_ids': AppDatabase.encodeStringList(q.folderIds),
  'exam_id': q.examId,
  'knowledge_ids': AppDatabase.encodeStringList(q.knowledgePointIds),
  'error_types': AppDatabase.encodeStringList(q.errorTypes),
  'custom_error_types': AppDatabase.encodeStringList(q.customErrorTypes),
  'tags': AppDatabase.encodeStringList(q.tags),
  'answer': q.answer,
  'explanation': q.explanation,
  'notes': q.notes,
  'review_count': q.reviewCount,
  'is_organized': q.isOrganized ? 1 : 0,
  'is_demo': q.isDemo ? 1 : 0,
  'is_favorite': q.isFavorite ? 1 : 0,
  'is_archived': q.isArchived ? 1 : 0,
  'review_joined': q.reviewJoined ? 1 : 0,
  'created_at': q.createdAt.millisecondsSinceEpoch,
  'slice_kind': q.sliceKind,
  'slice_text': q.sliceText,
  // §1.2(a)：图片链路列（全部可空）。
  'source_path': q.sourcePath,
  'source_kind': q.sourceKind,
  'source_page': q.sourcePage,
  'page_image_path': q.pageImagePath,
  'slice_path': q.slicePath,
  'slice_width': q.sliceWidth,
  'slice_height': q.sliceHeight,
};

Question _fromRow(Map<String, Object?> r) {
  return Question(
    id: r['id'] as String,
    title: r['title'] as String,
    subjectId: r['subject_id'] as String,
    folderIds: AppDatabase.decodeStringList(r['folder_ids']),
    examId: r['exam_id'] as String?,
    knowledgePointIds: AppDatabase.decodeStringList(r['knowledge_ids']),
    errorTypes: AppDatabase.decodeStringList(r['error_types']),
    customErrorTypes: AppDatabase.decodeStringList(r['custom_error_types']),
    tags: AppDatabase.decodeStringList(r['tags']),
    answer: r['answer'] as String?,
    explanation: r['explanation'] as String?,
    notes: r['notes'] as String?,
    reviewCount: (r['review_count'] as int?) ?? 0,
    isOrganized: (r['is_organized'] as int?) == 1,
    isDemo: (r['is_demo'] as int?) == 1,
    isFavorite: (r['is_favorite'] as int?) == 1,
    isArchived: (r['is_archived'] as int?) == 1,
    reviewJoined: (r['review_joined'] as int?) == 1,
    createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
    sliceKind: (r['slice_kind'] as String?) ?? 'material',
    sliceText: (r['slice_text'] as String?) ?? '',
    sourcePath: r['source_path'] as String?,
    sourceKind: r['source_kind'] as String?,
    sourcePage: r['source_page'] as int?,
    pageImagePath: r['page_image_path'] as String?,
    slicePath: r['slice_path'] as String?,
    sliceWidth: r['slice_width'] as int?,
    sliceHeight: r['slice_height'] as int?,
  );
}

CauseRecord _causeFromRow(Map<String, Object?> r) {
  return CauseRecord(
    questionId: r['question_id'] as String,
    cause: r['cause'] as String,
    subjectId: r['subject_id'] as String,
    status: switch (r['status'] as String?) {
      'inProgress' => CauseStatus.inProgress,
      'solved' => CauseStatus.solved,
      _ => CauseStatus.pending,
    },
    solvedCount: (r['solved_count'] as int?) ?? 0,
    lastCheck: r['last_check'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(r['last_check'] as int),
    recheckDate: r['recheck_date'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(r['recheck_date'] as int),
    remedyHistory: AppDatabase.decodeRemedyList(r['remedy_history']),
    joinedAt: DateTime.fromMillisecondsSinceEpoch(r['joined_at'] as int),
  );
}

Map<String, Object?> _causeRecordToRow(CauseRecord r) => {
  'question_id': r.questionId,
  'cause': r.cause,
  'subject_id': r.subjectId,
  'status': r.status.name,
  'solved_count': r.solvedCount,
  'last_check': r.lastCheck?.millisecondsSinceEpoch,
  'recheck_date': r.recheckDate?.millisecondsSinceEpoch,
  'remedy_history': AppDatabase.encodeRemedyList(r.remedyHistory),
  'joined_at': r.joinedAt.millisecondsSinceEpoch,
};

CollectTask _collectTaskFromRow(Map<String, Object?> r) {
  final createdMs = r['created_at'] as int?;
  // §1.6.1：page_rotations 是 JSON（{"1": 90}），键是字符串页码；
  // 读不到/非法时按 {} 处理（草稿无旋转）。
  Map<int, int> rotations = const {};
  final rawRotations = r['page_rotations'] as String?;
  if (rawRotations != null && rawRotations.isNotEmpty) {
    try {
      final decoded = jsonDecode(rawRotations);
      if (decoded is Map) {
        rotations = {
          for (final e in decoded.entries)
            if (int.tryParse('${e.key}') != null && e.value is num)
              int.parse('${e.key}'): (e.value as num).toInt(),
        };
      }
    } catch (_) {}
  }
  return CollectTask(
    id: r['id'] as String,
    name: r['name'] as String,
    fileName: r['file_name'] as String,
    subjectId: r['subject_id'] as String,
    status: CollectStatus.values.firstWhere(
      (s) => s.name == r['status'],
      orElse: () => CollectStatus.queued,
    ),
    progress: (r['progress'] as int?) ?? 0,
    pageCount: (r['page_count'] as int?) ?? 1,
    page: (r['page'] as int?) ?? 1,
    error: r['error'] as String?,
    questionId: r['question_id'] as String?,
    createdAt: createdMs == null || createdMs == 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(createdMs),
    sourcePath: (r['source_path'] as String?) ?? '',
    pageRotations: rotations,
  );
}

Map<String, Object?> _collectTaskToRow(CollectTask t) => {
  'id': t.id,
  'name': t.name,
  'file_name': t.fileName,
  'subject_id': t.subjectId,
  'status': t.status.name,
  'progress': t.progress,
  'page_count': t.pageCount,
  'page': t.page,
  'error': t.error,
  'question_id': t.questionId,
  // §1.2(b)：source_path 与 fileName 分离；page_rotations 写 JSON。
  'source_path': t.sourcePath,
  'page_rotations': jsonEncode({
    for (final e in t.pageRotations.entries) '${e.key}': e.value,
  }),
};

Map<String, Object?> _questionBoxToRow(QuestionBox b) => {
  'id': b.id,
  'collect_task_id': b.collectTaskId,
  'question_id': b.questionId,
  'parent_box_id': b.parentBoxId,
  'page': b.page,
  'layer': b.layer,
  'type': b.type,
  'x': b.x,
  'y': b.y,
  'w': b.w,
  'h': b.h,
  'confidence': b.confidence,
  'origin': b.origin,
  'updated_at': (b.updatedAt ?? DateTime.now()).millisecondsSinceEpoch,
};

QuestionBox _questionBoxFromRow(Map<String, Object?> r) => QuestionBox(
  id: r['id'] as String,
  collectTaskId: r['collect_task_id'] as String?,
  questionId: r['question_id'] as String?,
  parentBoxId: r['parent_box_id'] as String?,
  page: (r['page'] as int?) ?? 1,
  layer: (r['layer'] as int?) ?? 1,
  type: (r['type'] as String?) ?? 'question',
  x: (r['x'] as num).toDouble(),
  y: (r['y'] as num).toDouble(),
  w: (r['w'] as num).toDouble(),
  h: (r['h'] as num).toDouble(),
  confidence: (r['confidence'] as num?)?.toDouble(),
  origin: (r['origin'] as String?) ?? 'manual',
  updatedAt: r['updated_at'] == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
);
