// B4：database.dart 拆分——备份与恢复：JSON 导出/导入 / zip 备份/恢复 / 校验。
// 与 database.dart 同一库（part of），共享库私有成员；纯重构，行为不变。
//
// FR-26：一次 zip 恢复后数据库永久为 WAL 模式——[_takeRestoreSnapshot] 切的
// `PRAGMA journal_mode=WAL` 是持久化 pragma，恢复成功后无代码切回 delete
// （恢复成功后切回 delete 不做：须评估与快照 -wal/-shm 拷贝的交互，
// 风险大于收益）。第二次恢复时切 WAL 是空操作，快照互斥逻辑不受影响；
// 搬库代码已连 -wal/-shm 一起搬（见 db_storage.dart）。不要按
// “默认 journal_mode=delete”排障——该前提只对未恢复过的库成立。

part of 'database.dart';

/// B4.2：导出（可单测版）：直接对传入的库句柄导出，不碰单例。
/// §4.4：用 dart:convert 的 jsonEncode（手写 _jsonValue 只转义了
/// `\` / `"` / `\n`，漏 `\r` / `\t` / `\b` / `\f` 与其它控制字符，
/// 含制表符或回车的笔记会导出非法 JSON、恢复不了）。
/// §2.3：保持表名平铺在顶层，额外加 `_meta`
/// {schemaVersion, appVersion, exportedAt}（先加后用）。
Future<String> exportBackupJsonFromImpl(QuizDatabase db) async {
  final out = <String, dynamic>{
    '_meta': {
      'schemaVersion': AppDatabase.schemaVersion,
      'appVersion': AppDatabase.appVersion,
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
    },
  };
  for (final t in AppDatabase.backupTables) {
    // 十四批 M2（P1-6）：备份不含未完成会话——review_state 导出为 `[]`，
    // 恢复时也不插备份里的行（见 importBackupJsonIntoImpl），恢复事务
    // 中明确清空目标库现有的 review_state。
    if (t == 'review_state') {
      out[t] = const <dynamic>[];
      continue;
    }
    out[t] = (await db.customSelect('SELECT * FROM $t').get())
        .map((r) => r.data)
        .toList();
  }
  return jsonEncode(out);
}

/// §2.3：恢复前校验（纯校验，不动库；设置页选文件时先调它给即时
/// 反馈，importBackupJsonInto 里再调一次，双保险）。
/// 校验顺序：① `_meta.schemaVersion` 存在且为整数（缺失 → 按 v1
/// 备份处理，拒绝：v1 从未发布、老库已删，不存在合法的 v1 备份）；
/// ② v2、v3、v4 与 v5 放行（v2 备份恢复时迁移进 v5：新表缺键视为 empty，
/// collect_tasks 行缺 source_hash 视为 NULL；v3 备份恢复时迁移进 v5：
/// ocr_jobs 缺键视为 empty，questions 行缺 5 个 OCR 列走 DDL 默认值；
/// v4 备份恢复时迁移进 v5：attempts 缺键视为 empty，questions 行缺
/// 9 个 M1 列、cause_records 行缺 2 个锚点列、review_history 行缺
/// 8 个新字段、review_state 行缺 4 个会话列走 DDL 默认值），`> 5`
/// 拒绝（备份来自更新的版本），`< 2` 也拒绝；③ 按版本取表清单（v2 13 张、
/// v3 14 张、v4 15 张、v5 16 张），键齐全且为数组；④ 每行是对象、主键
/// 非空、必填列齐全且类型正确；⑤ 文件路径合法（见
/// [_validateBackupRowPaths]）；
/// ⑥ 9 个 JSON 列是字符串且能解析为对应形状（见
/// [_validateBackupRowJsonColumns]，FR-07）；
/// ⑦ 枚举/布尔列的值域（见 [_validateBackupRowDomains]，FR-23：
/// `cause_records.status` ∈ {pending, inProgress, solved}、
/// questions 的 5 个布尔列 ∈ {0, 1}；十三批 M2：questions 的
/// ocr_split_status ∈ {未切分, 自动切分, 存在歧义, 人工调整}、
/// ocr_manual_edited ∈ {0, 1}、ocr_jobs.status ∈ OcrJobStatus.values
/// 的枚举名（D-172：白名单直接取枚举，不再手写）；JSON 列非字符串由 ⑥ 覆盖）。
/// 任一步不过 → 抛 BackupRestoreException（带具体原因），
/// 调用方一律不动原库。
/// SR-P2-4：旧写法只强制 subjects/questions 为数组，其它表键缺失时
/// `rows == null → continue`，而恢复是“清表再插回”——一份缺了
/// cause_records 的备份恢复后会静默清空全部错因记录；只查
/// `containsKey('id')`，`id: null` 也能通过；不校验必填列/类型，
/// 非法行在恢复事务中途才抛原生 DatabaseException。
/// 新写法：缺表键即拒绝（不再按空表静默清空——设置页恢复入口没有
/// “缺表按空处理请确认”的二次确认口径）；主键 null 拒绝；每表
/// 必填列缺失或类型不对拒绝。插库时的残余异常见
/// [importBackupJsonIntoImpl] 的统一包装。
void validateBackupDataImpl(Map<String, dynamic> data) {
  final meta = data['_meta'];
  if (meta is! Map) {
    throw BackupRestoreException('这份备份没有版本信息，是旧版（v1）备份，新版不再支持恢复');
  }
  final sv = meta['schemaVersion'];
  if (sv is! int) {
    throw BackupRestoreException('这份备份没有版本信息，是旧版（v1）备份，新版不再支持恢复');
  }
  if (sv > AppDatabase.schemaVersion) {
    throw BackupRestoreException('这份备份来自更新的版本（v$sv），请先更新应用再恢复');
  }
  if (sv < 2) {
    throw BackupRestoreException('这份备份是旧版本（v$sv）的，新版不再支持恢复');
  }
  // 十二批 D-91：v2 备份仍可恢复（迁移进 v3）：新表缺键视为 empty，
  // collect_tasks 行缺 source_hash 列视为 NULL（无指纹基线）。
  // v2 的表清单只有 13 张，按版本取。
  // 十三批 M2：v3 备份仍可恢复（迁移进 v5）：ocr_jobs 缺键视为 empty，
  // questions 行缺 5 个 OCR 列走 DDL 默认值；v3 的表清单是 14 张。
  // 十四批 M2：v4 备份仍可恢复（迁移进 v5）：attempts 缺键视为 empty；
  // v4 的表清单是 15 张（backupTablesV4），v5 是 16 张。
  // Win11 反馈包 5：v5 备份仍可恢复（迁移进 v6）：questions 行缺
  // option_contents / option_contents_parser_version 两列走 NULL
  // 默认值；v5 的表清单也是 16 张（backupTablesV5）。
  final requiredTables = switch (sv) {
    2 => AppDatabase.backupTablesV2,
    3 => AppDatabase.backupTablesV3,
    4 => AppDatabase.backupTablesV4,
    5 => AppDatabase.backupTablesV5,
    _ => AppDatabase.backupTables,
  };
  for (final t in requiredTables) {
    final rows = data[t];
    // SR-P2-4：缺表键即拒绝，不再按空表处理（恢复是清表再插回，
    // 缺键按空处理等于静默清空该表，用户无从察觉）。
    if (rows is! List) {
      throw BackupRestoreException('这份备份文件已损坏：缺少 $t 表');
    }
    for (final row in rows) {
      if (row is! Map) {
        throw BackupRestoreException('这份备份文件已损坏：$t 表里有坏行');
      }
      _validateBackupRow(t, row);
      // FR-07：9 个 JSON 列的形状（非法 JSON / 元素类型错拒绝整个恢复，
      // 否则恢复插库时 decode* 会静默丢值）。
      _validateBackupRowJsonColumns(t, row);
      // FR-23：枚举/布尔列的值域（status 白名单、布尔列 ∈ {0, 1}）。
      _validateBackupRowDomains(t, row);
      // B3-P01：备份里的文件路径必须是 imports/ 或 slices/ 下
      // 的相对路径；绝对路径、`..` 穿越、其它目录一律拒绝整个
      // 恢复（明确报错，不静默跳过——跳过会让恢复结果不可预期）。
      _validateBackupRowPaths(t, row);
    }
  }
}

/// SR-P2-4：每表必填列（列名 → 值的类型）。只列 NOT NULL 的关键列：
/// 主键与业务上缺了就没法用的列；其余可空列缺失时插库走默认值或 NULL，
/// 不在这里拦。settings 用 `key` 作主键。
/// cause_records / review_history 的自增 id 缺失时允许（入库自动编号），
/// 出现时必须是非空整数；其余表 id 缺失或为 null 一律拒绝。
const Map<String, Map<String, Type>> _requiredBackupColumns = {
  'subjects': {'id': String, 'name': String, 'color': int},
  'questions': {'id': String, 'title': String, 'subject_id': String},
  'question_boxes': {'id': String},
  'folders': {'id': String, 'name': String, 'subject_id': String},
  'tags': {'id': String, 'name': String},
  'exams': {'id': String, 'name': String},
  'knowledge_points': {
    'id': String,
    'subject_id': String,
    'chapter': String,
    'name': String,
  },
  'cause_records': {
    'question_id': String,
    'cause': String,
    'subject_id': String,
  },
  'collect_tasks': {
    'id': String,
    'name': String,
    'file_name': String,
    'subject_id': String,
  },
  'review_state': {'id': int},
  'review_history': {
    'question_id': String,
    'result': String,
    'reviewed_at': int,
  },
  'recent_tasks': {
    'id': int,
    'kind': String,
    'subject_id': String,
    'title': String,
  },
  'recently_viewed_questions': {
    'question_id': String,
    'viewed_at': int,
  },
  // 十三批 M2：ocr_jobs（主键 id；created_at / updated_at 是 NOT NULL
  // 列，插库时 _ri 会拦缺失/类型错，这里只列业务必填列，与 questions
  // 只列 id/title/subject_id 的口径一致）。
  'ocr_jobs': {'id': String, 'question_id': String},
  // 十四批 M2：attempts（主键 id；question_id 是业务必填列；
  // session_id / mode / status / created_at 是 NOT NULL 列，
  // 插库时 _rs/_ri 会拦缺失/类型错，值域见 _validateBackupRowDomains）。
  'attempts': {'id': String, 'question_id': String},
  'settings': {'key': String, 'value': String},
};

/// 整数主键的表（自增或 CHECK(id = 1) 的单行表）。
const _integerIdBackupTables = {
  'cause_records',
  'review_history',
  'review_state',
  'recent_tasks',
};

/// 各表备份行的真实主键列（校验口径以真实主键为准）。
/// D-101：旧写法把所有非整数主键表都按 `id` 校验，但
/// recently_viewed_questions 的主键是 question_id
///（db_schema.dart：`question_id TEXT PRIMARY KEY`），根本没有
/// id 列——有浏览历史的备份一恢复就报“缺少主键 id”（备份本身没坏）。
/// 十三批 M2：ocr_jobs 的主键就是 id（默认口径已对），settings 的主键
/// 是 key，recently_viewed_questions 的主键是 question_id；其余表默认 id。
const _backupPkColumn = {
  'settings': 'key',
  'recently_viewed_questions': 'question_id',
};

void _validateBackupRow(String table, Map row) {
  // D-101：主键列按表取真实值（_backupPkColumn），其余表默认 `id`。
  final pkColumn = _backupPkColumn[table] ?? 'id';
  final id = row[pkColumn] ?? row['id'] ?? row['key'] ?? '?';
  // 主键非空：TEXT 主键必须是非空字符串；整数主键出现时
  // 必须是非空整数；cause_records / review_history 的自增 id
  // 缺失时允许（入库自动编号），review_state / recent_tasks
  // 的 id 由必填列检查覆盖（_requiredBackupColumns 里是 int）。
  // SR2-16：`''` 是合法 String，旧写法只查 `is! String` 会放过
  // 空串主键（SQLite 的 TEXT PRIMARY KEY 允许空串），恢复后库里
  // 出现脏行；必填 String 列同理。空串拒绝口径落在真实主键列上。
  if (_integerIdBackupTables.contains(table)) {
    if (row.containsKey('id') && row['id'] is! int) {
      throw BackupRestoreException('这份备份文件已损坏：$table 表 $id 行的主键 id 为空或类型不对');
    }
  } else if (row[pkColumn] is! String || (row[pkColumn] as String).isEmpty) {
    throw BackupRestoreException('这份备份文件已损坏：$table 表里有行缺少主键 $pkColumn');
  }
  final required = _requiredBackupColumns[table];
  if (required == null) return;
  for (final e in required.entries) {
    final value = row[e.key];
    if (value == null) {
      throw BackupRestoreException('这份备份文件已损坏：$table 表 $id 行缺少必填列 ${e.key}');
    }
    var ok = e.value == int ? value is int : value is String;
    // SR2-16：必填 String 列空串也拒绝（与主键同口径）；例外是
    // settings.value——它是通用值列，空串是合法设置值（如清空
    // 问候语），只要求它是 String。
    if (ok && e.value == String && value is String && value.isEmpty) {
      if (table != 'settings' || e.key != 'value') ok = false;
    }
    if (!ok) {
      throw BackupRestoreException('这份备份文件已损坏：$table 表 $id 行的 ${e.key} 类型不对');
    }
  }
}

/// FR-07：校验备份里 9 个 JSON 列的形状（与
/// [AppDatabase.decodeStringList]/[decodeQueue]/[decodeRotations] 的
/// 读侧口径同形）。值必须是字符串且能解析为对应形状，否则拒绝整个
/// 恢复（与必填列同口径——decode* 本身保持宽容，供应用内读侧用；
/// 校验层在这里拦，非法值进不了库，也就不会在恢复插库时被 decode*
/// 静默丢掉）。
/// `''` / null → 空集合的 D-51 规范化口径不变（放行）；键缺失放行
/// （FR-21 是批二的项）；非字符串值与非法 JSON 一律拒绝。
void _validateBackupRowJsonColumns(String table, Map row) {
  // 字符串列表列：questions 的 5 个多值字段 + cause_records.remedy_history。
  // 十四批 M1：option_labels 也是字符串列表列（NULL = 未确认，放行）。
  // 十四批 M2：attempts.cause_ids 也是字符串列表列（本次作答关联的
  // 本轮错因 id 列表；NULL 按 D-51 放行，插库时走 DDL 默认值 '[]'）。
  const stringListColumns = {
    'questions': [
      'folder_ids',
      'knowledge_ids',
      'error_types',
      'custom_error_types',
      'tags',
      'option_labels',
    ],
    'cause_records': ['remedy_history'],
    'attempts': ['cause_ids'],
  };
  final id = row['id'] ?? row['key'] ?? '?';
  void reject(String col, String expected, Object? value) {
    throw BackupRestoreException(
      '这份备份文件已损坏：$table 表 $id 行的 $col 不是合法的 JSON'
      '（应为$expected）：$value',
    );
  }

  bool validStringList(Object? value) {
    if (value == null) return true; // D-51：null → 空集合，放行
    if (value is! String) return false;
    if (value.isEmpty) return true; // D-51：'' → 空集合，放行
    try {
      final decoded = jsonDecode(value);
      return decoded is List && decoded.every((e) => e is String);
    } catch (_) {
      return false;
    }
  }

  final columns = stringListColumns[table];
  if (columns != null) {
    for (final col in columns) {
      if (!row.containsKey(col)) continue; // 键缺失放行（FR-21 批二）
      if (!validStringList(row[col])) {
        reject(col, '字符串数组', row[col]);
      }
    }
  }
  // Win11 反馈包 5：questions.option_contents 是标签到选项文字的
  // JSON 对象（不是字符串数组）：键缺失放行（v5 备份走 NULL 默认值）；
  // 键在但为 null 放行（未解析）；非字符串或非法 JSON 对象一律拒绝。
  if (table == 'questions' && row.containsKey('option_contents')) {
    final value = row['option_contents'];
    if (value != null &&
        (value is! String || !isValidOptionContentsJson(value))) {
      reject('option_contents', '标签到选项文字的 JSON 对象', value);
    }
  }
  // Win11 反馈包 5：option_contents_parser_version 是可空整数（≥0）。
  if (table == 'questions' &&
      row.containsKey('option_contents_parser_version')) {
    final value = row['option_contents_parser_version'];
    if (value != null && (value is! int || value < 0)) {
      reject('option_contents_parser_version', '≥0 的整数版本号', value);
    }
  }
  // review_state.queue：含 q/c 字符串的对象数组。
  if (table == 'review_state' && row.containsKey('queue')) {
    final value = row['queue'];
    var ok = value == null;
    if (value is String && value.isEmpty) ok = true; // D-51
    if (value is String && value.isNotEmpty) {
      try {
        final decoded = jsonDecode(value);
        ok =
            decoded is List &&
            decoded.every(
              (e) => e is Map && e['q'] is String && e['c'] is String,
            );
      } catch (_) {
        ok = false;
      }
    }
    if (!ok) reject('queue', '含 q/c 字符串的对象数组', value);
  }
  // collect_tasks.page_rotations：键为页码、值为角度的 JSON 对象。
  if (table == 'collect_tasks' && row.containsKey('page_rotations')) {
    final value = row['page_rotations'];
    var ok = value == null;
    if (value is String && value.isEmpty) ok = true; // D-51
    if (value is String && value.isNotEmpty) {
      try {
        final decoded = jsonDecode(value);
        ok =
            decoded is Map &&
            decoded.entries.every(
              (e) => int.tryParse('${e.key}') != null && e.value is num,
            );
      } catch (_) {
        ok = false;
      }
    }
    if (!ok) reject('page_rotations', '键为页码、值为角度的 JSON 对象', value);
  }
}

/// FR-23：校验备份里枚举/布尔列的值域（与 FR-07 的 JSON 形状检查并列，
/// 同在校验层、恢复覆盖原库之前拦）。
/// - `cause_records.status` ∈ {pending, inProgress, solved}（读侧对未知
///   status 静默回落 pending，见 db_questions.dart，非法值不得入库）；
/// - `questions` 的 5 个布尔列（is_organized / is_demo / is_favorite /
///   is_archived / review_joined）∈ {0, 1}（读侧 `!= 1` 即 false，非法值
///   不得入库）。报告称“6 个布尔列”，DDL（db_schema.dart questions 表）
///   里实际只有这 5 个，按实际列校验（见批报告）。
/// - JSON 列须为字符串或缺失：已由 FR-07 的 [_validateBackupRowJsonColumns]
///   覆盖（非字符串值拒绝），这里不重复造轮子。
/// 键缺失放行（走 DDL 默认值）；键在但值为 null 或域外值 → 拒绝整个恢复。
void _validateBackupRowDomains(String table, Map row) {
  final id = row['id'] ?? row['key'] ?? '?';
  if (table == 'cause_records' && row.containsKey('status')) {
    final value = row['status'];
    if (value is! String ||
        (value != 'pending' && value != 'inProgress' && value != 'solved')) {
      throw BackupRestoreException(
        '这份备份文件已损坏：cause_records 表 $id 行的 status 不是合法的'
        '错因状态（应为 pending / inProgress / solved）：$value',
      );
    }
  }
  // D-257：subjects 的手动标记 ∈ {0, 1}。键缺失放行（走 DDL 默认值 0）；
  // 键在但域外值 → 拒绝整个恢复。
  if (table == 'subjects' && row.containsKey('english_name_manual')) {
    final value = row['english_name_manual'];
    if (value is! int || (value != 0 && value != 1)) {
      throw BackupRestoreException(
        '这份备份文件已损坏：subjects 表 $id 行的 english_name_manual 不是合法的'
        '布尔值（应为 0 或 1）：$value',
      );
    }
  }
  if (table == 'questions') {
    const boolColumns = [
      'is_organized',
      'is_demo',
      'is_favorite',
      'is_archived',
      'review_joined',
    ];
    for (final col in boolColumns) {
      if (!row.containsKey(col)) continue;
      final value = row[col];
      if (value is! int || (value != 0 && value != 1)) {
        throw BackupRestoreException(
          '这份备份文件已损坏：questions 表 $id 行的 $col 不是合法的'
          '布尔值（应为 0 或 1）：$value',
        );
      }
    }
    // 十三批 M2：OCR 列的值域。键缺失放行（走 DDL 默认值）；键在但值
    // 为 null 或域外值 → 拒绝整个恢复。
    if (row.containsKey('ocr_split_status')) {
      final value = row['ocr_split_status'];
      if (value is! String ||
          (value != '未切分' &&
              value != '自动切分' &&
              value != '存在歧义' &&
              value != '人工调整')) {
        throw BackupRestoreException(
          '这份备份文件已损坏：questions 表 $id 行的 ocr_split_status 不是合法的'
          '切分状态（应为 未切分 / 自动切分 / 存在歧义 / 人工调整）：$value',
        );
      }
    }
    if (row.containsKey('ocr_manual_edited')) {
      final value = row['ocr_manual_edited'];
      if (value is! int || (value != 0 && value != 1)) {
        throw BackupRestoreException(
          '这份备份文件已损坏：questions 表 $id 行的 ocr_manual_edited 不是合法的'
          '布尔值（应为 0 或 1）：$value',
        );
      }
    }
    // 十四批 M1：题型列的值域（D-119）。键缺失放行（走 DDL 默认值）；
    // 键在但值为 null（question_type 允许 null = 待确认）或域外值 →
    // 拒绝整个恢复。17 个值与 question_classifier.questionTypeValues
    // 同步，改枚举时两处一起改。
    if (row.containsKey('question_type')) {
      const types = {
        'choice_single',
        'choice_multi',
        'choice_variable',
        'true_false',
        'fill_blank',
        'calculation',
        'proof',
        'short_answer',
        'essay',
        'matching',
        'ordering',
        'diagram_label',
        'programming',
        'experiment_analysis',
        'translation',
        'writing',
        'other',
      };
      final value = row['question_type'];
      if (value != null && (value is! String || !types.contains(value))) {
        throw BackupRestoreException(
          '这份备份文件已损坏：questions 表 $id 行的 question_type 不是合法的'
          '题型（应为 17 个题型值之一或 null）：$value',
        );
      }
    }
    if (row.containsKey('option_labels_confirmed')) {
      final value = row['option_labels_confirmed'];
      if (value is! int || (value != 0 && value != 1)) {
        throw BackupRestoreException(
          '这份备份文件已损坏：questions 表 $id 行的 option_labels_confirmed 不是合法的'
          '布尔值（应为 0 或 1）：$value',
        );
      }
    }
  }
  // 十四批 M1：review_history 新增字段的值域（D-119）。各列都可空：
  // null 放行（旧行本来就是 NULL）；非 null 时须在域内。跨字段一致性
  // （已核验/未核验与来源的搭配）由 DDL CHECK 在插库时 enforced，
  // 插库异常统一包成 BackupRestoreException。
  if (table == 'review_history') {
    if (row.containsKey('review_mode')) {
      final value = row['review_mode'];
      if (value != null && value != '到期复习') {
        throw BackupRestoreException(
          '这份备份文件已损坏：review_history 表 $id 行的 review_mode 不是合法的'
          '复习模式（应为 到期复习 或 null）：$value',
        );
      }
    }
    if (row.containsKey('verification_status')) {
      final value = row['verification_status'];
      if (value != null && value != '已核验' && value != '未核验') {
        throw BackupRestoreException(
          '这份备份文件已损坏：review_history 表 $id 行的 verification_status 不是合法的'
          '核验状态（应为 已核验 / 未核验 或 null）：$value',
        );
      }
    }
    if (row.containsKey('verification_source')) {
      final value = row['verification_source'];
      if (value != null &&
          value != '软件标准答案' &&
          value != '客观判分' &&
          value != '外部资料核对' &&
          value != '未核验') {
        throw BackupRestoreException(
          '这份备份文件已损坏：review_history 表 $id 行的 verification_source 不是合法的'
          '核验来源（应为 软件标准答案 / 客观判分 / 外部资料核对 / 未核验 或 null）：$value',
        );
      }
    }
  }
  // 十三批 M2：ocr_jobs.status ∈ OcrJobStatus.values 的枚举名。
  // D-172：白名单直接取枚举——取消识别包 2 加 cancelled 时只改了
  // 枚举，这里仍是旧 4 值，含 cancelled 行的备份被误判损坏。
  if (table == 'ocr_jobs' && row.containsKey('status')) {
    final value = row['status'];
    if (value is! String ||
        !OcrJobStatus.values.any((s) => s.name == value)) {
      throw BackupRestoreException(
        '这份备份文件已损坏：ocr_jobs 表 $id 行的 status 不是合法的'
        '任务状态（应为 ${OcrJobStatus.values.map((s) => s.name).join(' / ')}）：$value',
      );
    }
  }
  // 十四批 M2：attempts 各列的值域（PLAN-14-REV4.3 M3 口径；M3 若
  // 改枚举，两处一起改）。键缺失放行（走 DDL 默认值）；键在但值为
  // null（可空列）或域外值 → 拒绝整个恢复。
  // mode ∈ {到期复习, 专项练习}；status ∈ {已提交, 已完成作答, 跳过}；
  // confidence ∈ {确定, 不太确定, 猜的} 或 null；
  // correct ∈ {0, 1} 或 null；answer_version / content_version 为 ≥0 整数。
  if (table == 'attempts') {
    if (row.containsKey('mode')) {
      final value = row['mode'];
      if (value is! String || (value != '到期复习' && value != '专项练习')) {
        throw BackupRestoreException(
          '这份备份文件已损坏：attempts 表 $id 行的 mode 不是合法的'
          '作答模式（应为 到期复习 / 专项练习）：$value',
        );
      }
    }
    if (row.containsKey('status')) {
      final value = row['status'];
      if (value is! String ||
          (value != '已提交' && value != '已完成作答' && value != '跳过')) {
        throw BackupRestoreException(
          '这份备份文件已损坏：attempts 表 $id 行的 status 不是合法的'
          '作答状态（应为 已提交 / 已完成作答 / 跳过）：$value',
        );
      }
    }
    if (row.containsKey('confidence')) {
      final value = row['confidence'];
      if (value != null &&
          (value is! String ||
              (value != '确定' && value != '不太确定' && value != '猜的'))) {
        throw BackupRestoreException(
          '这份备份文件已损坏：attempts 表 $id 行的 confidence 不是合法的'
          '作答前置信度（应为 确定 / 不太确定 / 猜的 或 null）：$value',
        );
      }
    }
    if (row.containsKey('correct')) {
      final value = row['correct'];
      if (value != null && (value is! int || (value != 0 && value != 1))) {
        throw BackupRestoreException(
          '这份备份文件已损坏：attempts 表 $id 行的 correct 不是合法的'
          '判分结果（应为 0 / 1 或 null）：$value',
        );
      }
    }
    for (final col in ['answer_version', 'content_version']) {
      if (row.containsKey(col)) {
        final value = row[col];
        if (value is! int || value < 0) {
          throw BackupRestoreException(
            '这份备份文件已损坏：attempts 表 $id 行的 $col 不是合法的'
            '版本号（应为 ≥0 的整数）：$value',
          );
        }
      }
    }
  }
}

/// B3-P01：校验备份里一行携带的文件路径（见
/// [AppDatabase.isAllowedDataRelativePath]）。只校验存文件路径的列：
/// questions 的 source_path / page_image_path / slice_path，
/// collect_tasks 的 source_path，ocr_jobs 的 crop_path（十三批 M2：
/// 本次识别用的切片，相对数据目录、imports/ 或 slices/ 下）。
/// 空值（null / ''）表示没有文件，放行；非字符串或不合法路径 → 抛
/// [BackupRestoreException]（带表名、行 id、列名与原值，拒绝整个恢复）。
void _validateBackupRowPaths(String table, Map row) {
  const pathColumns = {
    'questions': ['source_path', 'page_image_path', 'slice_path'],
    'collect_tasks': ['source_path'],
    'ocr_jobs': ['crop_path'],
  };
  final columns = pathColumns[table];
  if (columns == null) return;
  final id = row['id'] ?? row['key'] ?? '?';
  for (final col in columns) {
    final value = row[col];
    if (value == null) continue;
    if (value is! String || !AppDatabase.isAllowedDataRelativePath(value)) {
      throw BackupRestoreException(
        '这份备份里 $table 表 $id 行的 $col 路径不合法：$value'
        '（只允许 imports/ 或 slices/ 下的相对路径）',
      );
    }
  }
}

/// B3：备份恢复插行（类型化版）——替代手拼 SQL 的旧 `_backupInsertRow`
///（`INSERT OR REPLACE INTO $table (...) VALUES (...)` 动态拼列）。
/// 行来自 JSON，值是存储表示：
/// - JSON 列（questions 的 5 个多值字段、cause_records.remedy_history、
///   review_state.queue、collect_tasks.page_rotations）先经
///   `AppDatabase.decode*` 解回业务值，再由各列的 TypeConverter 编回
///   存储表示。解码与编码互逆，规范值逐字节不变；非规范旧值 ''（DDL
///   DEFAULT 遗留）解码为空集合、编回规范的 '[]' / '{}'（与 p2_json_fields
///   回归口径一致：'' 是漂移，'[]' 是规范；语义等价，
///   `decode('') == decode('[]')`）。键缺失时走 `Value.absent()`
///   （FR-21：不写该列、落 DDL 默认值，与旧写法“缺键不写”同口径；
///   键在但值是 '' 时仍按 D-51 编回规范值）。
/// - 其余列按 JSON 里的运行时类型严格取值（见 `_rs` / `_ri` / `_rd`
///   系列助手）：缺失或类型不对直接抛 [BackupRestoreException]，不静默
///   默认值、不猜测转换；有 DDL 默认值的可选列缺失时走 `Value.absent()`
///  （落库默认值，与旧写法“缺键不写”同口径）。
/// 插库用 `InsertMode.insertOrReplace`，与旧 INSERT OR REPLACE 同语义
///（自增 id 缺失时自动编号，与旧写法同口径）。
Future<void> _backupInsertRowTyped(
  QuizDatabase db,
  String table,
  Map<String, Object?> row,
) async {
  // 旧 `_backupInsertRow` 是按行实际键拼 INSERT，表里没有的列会在插库时
  // 让 SQLite 报错（“不能静默丢列”）；类型化映射只认已知列，未知列
  // 不会进 Companion，必须在这里先拦，否则会静默丢掉备份里的数据。
  const knownColumns = <String, Set<String>>{
    'subjects': {
      'id',
      'name',
      'color',
      'cover_style',
      'cover_color',
      // D-257：英文名与手动标记（v7 新增；旧备份缺键时插库走
      // NULL / DDL 默认值 0）。
      'english_name',
      'english_name_manual',
    },
    'questions': {
      'id',
      'title',
      'subject_id',
      'folder_ids',
      'exam_id',
      'knowledge_ids',
      'error_types',
      'custom_error_types',
      'tags',
      'answer',
      'explanation',
      'notes',
      'review_count',
      'is_organized',
      'is_demo',
      'is_favorite',
      'is_archived',
      'review_joined',
      'created_at',
      'slice_kind',
      'slice_text',
      'source_path',
      'source_kind',
      'source_page',
      'page_image_path',
      'slice_path',
      'slice_width',
      'slice_height',
      // 十三批 M2：OCR 列。
      'ocr_raw',
      'ocr_stem',
      'ocr_split_status',
      'ocr_manual_edited',
      'content_version',
      // 十四批 M1：题型列。D-119：PLAN 假设导出是显式列白名单
      // （E10），实际导出是 SELECT *，新列已进备份文件；导入白名单
      // 若不跟进，v5 备份往返全断、既有测试全红。只做“接受并原样
      // 恢复”这一最小修复；attempts 入备份、图块 ZIP 归档仍是 M2。
      'question_type',
      'question_type_source',
      'question_background_tags',
      'question_background_tags_source',
      'ocr_figures',
      'correct_option',
      'option_labels',
      'option_labels_confirmed',
      'answer_version',
      // 十四批 M3（P1-A）：答案待重新核对标记。
      'answer_pending_recheck',
      // Win11 反馈包 5：选项内容（标签映射 JSON）与解析器版本。
      'option_contents',
      'option_contents_parser_version',
    },
    'question_boxes': {
      'id',
      'collect_task_id',
      'question_id',
      'parent_box_id',
      'page',
      'layer',
      'type',
      'x',
      'y',
      'w',
      'h',
      'confidence',
      'origin',
      'updated_at',
    },
    'folders': {'id', 'name', 'subject_id', 'parent_id', 'sort_order'},
    'tags': {'id', 'name'},
    'exams': {'id', 'name', 'date'},
    'knowledge_points': {'id', 'subject_id', 'chapter', 'name'},
    'cause_records': {
      'id',
      'question_id',
      'cause',
      'subject_id',
      'status',
      'solved_count',
      'last_check',
      'recheck_date',
      'remedy_history',
      'joined_at',
      // 十四批 M1：治愈锚点列（D-119 同款最小修复）。
      'last_counted_success_at',
      'last_counted_session_id',
    },
    'collect_tasks': {
      'id',
      'name',
      'file_name',
      'subject_id',
      'status',
      'progress',
      'page_count',
      'page',
      'error',
      'question_id',
      'created_at',
      'source_path',
      'page_rotations',
      'source_hash',
    },
    // 十四批 M1：review_state 新增列与 review_history 新增字段
    //（D-119 同款最小修复：接受并原样恢复；attempts 入备份仍是 M2）。
    'review_state': {
      'id',
      'queue',
      'position',
      'updated_at',
      'session_id',
      'mode',
      'skips',
      'per_question_state',
    },
    'review_history': {
      'id',
      'question_id',
      'result',
      'reviewed_at',
      'cause_id',
      'session_id',
      'review_mode',
      'verdict',
      'verification_status',
      'verification_source',
      'attempt_id',
      'submission_id',
    },
    'recent_tasks': {'id', 'kind', 'subject_id', 'title', 'updated_at'},
    'recently_viewed_questions': {'question_id', 'viewed_at'},
    // 十三批 M2：ocr_jobs（GPT 评审 §2.2 字段表，15 列全列出；
    // 十三批 P1-1 加 lease_token）。
    'ocr_jobs': {
      'id',
      'question_id',
      'crop_path',
      'input_hash',
      'status',
      'attempt_count',
      'available_at',
      'started_at',
      'lease_until',
      'lease_token',
      'last_error_code',
      'last_error_message',
      'created_at',
      'updated_at',
      'completed_at',
    },
    // 十四批 M2：attempts 全表（P1-6）。cause_ids 是原始 JSON 字符串
    // 列（无 TypeConverter），插库时原样写回，不经 decode。
    'attempts': {
      'id',
      'question_id',
      'session_id',
      'mode',
      'selected',
      'correct',
      'confidence',
      'answer_version',
      'content_version',
      'status',
      'cause_ids',
      'duration_ms',
      'submission_id',
      'created_at',
    },
    'settings': {'key', 'value'},
  };
  final allowed = knownColumns[table];
  if (allowed == null) {
    throw BackupRestoreException('这份备份数据有问题：未知表 $table');
  }
  for (final key in row.keys) {
    if (!allowed.contains(key)) {
      throw BackupRestoreException(
        '这份备份数据有问题：$table 表 ${_rowLabel(row)} 行有多余的列 $key',
      );
    }
  }
  switch (table) {
    case 'subjects':
      await db
          .into(db.subjects)
          .insert(
            SubjectsCompanion(
              id: Value(_rs(row, 'id')),
              name: Value(_rs(row, 'name')),
              color: Value(_ri(row, 'color')),
              coverStyle: _vStrDef(row, 'cover_style'),
              coverColor: _vStrDef(row, 'cover_color'),
              // D-257：英文名（可空列，缺键写 NULL）与手动标记
              //（缺键走 Value.absent() 落 DDL 默认值 0）。
              englishName: Value(_rsN(row, 'english_name')),
              englishNameManual: _vIntDef(row, 'english_name_manual'),
            ),
            mode: InsertMode.insertOrReplace,
          );
    case 'questions':
      await db
          .into(db.questions)
          .insert(
            QuestionsCompanion(
              id: Value(_rs(row, 'id')),
              title: Value(_rs(row, 'title')),
              subjectId: Value(_rs(row, 'subject_id')),
              folderIds: _vStringListDef(row, 'folder_ids'),
              examId: Value(_rsN(row, 'exam_id')),
              knowledgeIds: _vStringListDef(row, 'knowledge_ids'),
              errorTypes: _vStringListDef(row, 'error_types'),
              customErrorTypes: _vStringListDef(row, 'custom_error_types'),
              tags: _vStringListDef(row, 'tags'),
              answer: Value(_rsN(row, 'answer')),
              explanation: Value(_rsN(row, 'explanation')),
              notes: Value(_rsN(row, 'notes')),
              reviewCount: _vIntDef(row, 'review_count'),
              isOrganized: _vIntDef(row, 'is_organized'),
              isDemo: _vIntDef(row, 'is_demo'),
              isFavorite: _vIntDef(row, 'is_favorite'),
              isArchived: _vIntDef(row, 'is_archived'),
              reviewJoined: _vIntDef(row, 'review_joined'),
              createdAt: Value(_ri(row, 'created_at')),
              sliceKind: _vStrDef(row, 'slice_kind'),
              sliceText: _vStrDef(row, 'slice_text'),
              sourcePath: Value(_rsN(row, 'source_path')),
              sourceKind: Value(_rsN(row, 'source_kind')),
              sourcePage: Value(_riN(row, 'source_page')),
              pageImagePath: Value(_rsN(row, 'page_image_path')),
              slicePath: Value(_rsN(row, 'slice_path')),
              sliceWidth: Value(_riN(row, 'slice_width')),
              sliceHeight: Value(_riN(row, 'slice_height')),
              // 十三批 M2：OCR 列。v2/v3 备份行缺这些键时走 Value.absent()
              // 落 DDL 默认值（ocr_raw/ocr_stem 为 NULL、ocr_split_status
              // 为 '未切分'、ocr_manual_edited/content_version 为 0），
              // 与旧写法“缺键不写”同口径。
              ocrRaw: Value(_rsN(row, 'ocr_raw')),
              ocrStem: Value(_rsN(row, 'ocr_stem')),
              ocrSplitStatus: _vStrDef(row, 'ocr_split_status'),
              ocrManualEdited: _vIntDef(row, 'ocr_manual_edited'),
              contentVersion: _vIntDef(row, 'content_version'),
              // 十四批 M1：题型列（D-119）。缺键走 Value.absent() 落 DDL
              // 默认值（v4/更早备份同口径）；NOT NULL 列键在但值为 null
              // 时 _vStrDef/_vIntDef 抛错，不静默默认值。option_labels
              // 是可空 JSON 列表列：NULL = 未确认，与 '[]' 不同义，
              // 键在且值为 null 时写 NULL，不解成 []。
              questionType: Value(_rsN(row, 'question_type')),
              questionTypeSource: _vStrDef(row, 'question_type_source'),
              questionBackgroundTags: _vStrDef(row, 'question_background_tags'),
              questionBackgroundTagsSource: _vStrDef(
                row,
                'question_background_tags_source',
              ),
              ocrFigures: _vStrDef(row, 'ocr_figures'),
              correctOption: Value(_rsN(row, 'correct_option')),
              optionLabels: row.containsKey('option_labels')
                  ? Value(
                      row['option_labels'] == null
                          ? null
                          : AppDatabase.decodeStringList(
                              row['option_labels'],
                            ),
                    )
                  : const Value.absent(),
              optionLabelsConfirmed: _vIntDef(row, 'option_labels_confirmed'),
              answerVersion: _vIntDef(row, 'answer_version'),
              // 十四批 M3（P1-A）：缺键走 DDL 默认值 0（v4/旧 v5 备份同口径）。
              answerPendingRecheck: _vIntDef(row, 'answer_pending_recheck'),
              // Win11 反馈包 5：选项内容原样写回（不经 decode：备份里的
              // JSON 文本就是存储表示；键缺失走 Value.absent() 落 DDL
              // 默认值 NULL，v5 备份同口径；键在但值为 null 写 NULL）。
              // 解析器版本缺键/NULL 都写 NULL。
              optionContents: row.containsKey('option_contents')
                  ? Value(
                      row['option_contents'] == null
                          ? null
                          : _rs(row, 'option_contents'),
                    )
                  : const Value.absent(),
              optionContentsParserVersion:
                  row.containsKey('option_contents_parser_version')
                  ? Value(
                      _riN(row, 'option_contents_parser_version'),
                    )
                  : const Value.absent(),
            ),
            mode: InsertMode.insertOrReplace,
          );
    case 'question_boxes':
      await db
          .into(db.questionBoxes)
          .insert(
            QuestionBoxesCompanion(
              id: Value(_rs(row, 'id')),
              collectTaskId: Value(_rsN(row, 'collect_task_id')),
              questionId: Value(_rsN(row, 'question_id')),
              parentBoxId: Value(_rsN(row, 'parent_box_id')),
              page: _vIntDef(row, 'page'),
              layer: Value(_ri(row, 'layer')),
              type: Value(_rs(row, 'type')),
              x: Value(_rd(row, 'x')),
              y: Value(_rd(row, 'y')),
              w: Value(_rd(row, 'w')),
              h: Value(_rd(row, 'h')),
              confidence: Value(_rdN(row, 'confidence')),
              origin: _vStrDef(row, 'origin'),
              updatedAt: Value(_ri(row, 'updated_at')),
            ),
            mode: InsertMode.insertOrReplace,
          );
    case 'folders':
      await db
          .into(db.folders)
          .insert(
            FoldersCompanion(
              id: Value(_rs(row, 'id')),
              name: Value(_rs(row, 'name')),
              subjectId: Value(_rs(row, 'subject_id')),
              parentId: Value(_rsN(row, 'parent_id')),
              sortOrder: _vIntDef(row, 'sort_order'),
            ),
            mode: InsertMode.insertOrReplace,
          );
    case 'tags':
      await db
          .into(db.tags)
          .insert(
            TagsCompanion(
              id: Value(_rs(row, 'id')),
              name: Value(_rs(row, 'name')),
            ),
            mode: InsertMode.insertOrReplace,
          );
    case 'exams':
      await db
          .into(db.exams)
          .insert(
            ExamsCompanion(
              id: Value(_rs(row, 'id')),
              name: Value(_rs(row, 'name')),
              date: Value(_riN(row, 'date')),
            ),
            mode: InsertMode.insertOrReplace,
          );
    case 'knowledge_points':
      await db
          .into(db.knowledgePoints)
          .insert(
            KnowledgePointsCompanion(
              id: Value(_rs(row, 'id')),
              subjectId: Value(_rs(row, 'subject_id')),
              chapter: Value(_rs(row, 'chapter')),
              name: Value(_rs(row, 'name')),
            ),
            mode: InsertMode.insertOrReplace,
          );
    case 'cause_records':
      await db
          .into(db.causeRecords)
          .insert(
            CauseRecordsCompanion(
              id: row['id'] is int
                  ? Value(row['id'] as int)
                  : const Value.absent(),
              questionId: Value(_rs(row, 'question_id')),
              cause: Value(_rs(row, 'cause')),
              subjectId: Value(_rs(row, 'subject_id')),
              status: _vStrDef(row, 'status'),
              solvedCount: _vIntDef(row, 'solved_count'),
              lastCheck: Value(_riN(row, 'last_check')),
              recheckDate: Value(_riN(row, 'recheck_date')),
              remedyHistory: _vStringListDef(row, 'remedy_history'),
              joinedAt: Value(_ri(row, 'joined_at')),
              // 十四批 M1：治愈锚点列（D-119）。缺键/NULL 都写 NULL。
              lastCountedSuccessAt: Value(
                _riN(row, 'last_counted_success_at'),
              ),
              lastCountedSessionId: Value(
                _rsN(row, 'last_counted_session_id'),
              ),
            ),
            mode: InsertMode.insertOrReplace,
          );
    case 'collect_tasks':
      await db
          .into(db.collectTasks)
          .insert(
            CollectTasksCompanion(
              id: Value(_rs(row, 'id')),
              name: Value(_rs(row, 'name')),
              fileName: Value(_rs(row, 'file_name')),
              subjectId: Value(_rs(row, 'subject_id')),
              status: _vStrDef(row, 'status'),
              progress: _vIntDef(row, 'progress'),
              pageCount: _vIntDef(row, 'page_count'),
              page: _vIntDef(row, 'page'),
              error: Value(_rsN(row, 'error')),
              questionId: Value(_rsN(row, 'question_id')),
              createdAt: _vIntDef(row, 'created_at'),
              sourcePath: _vStrDef(row, 'source_path'),
              pageRotations: _vRotationsDef(row, 'page_rotations'),
              // 十二批 D-91：v2 备份行缺 source_hash → Value.absent()
              // 落 NULL（无指纹基线）；有则校验为字符串或 null。
              sourceHash: row.containsKey('source_hash')
                  ? Value(_rsN(row, 'source_hash'))
                  : const Value.absent(),
            ),
            mode: InsertMode.insertOrReplace,
          );
    case 'review_state':
      await db
          .into(db.reviewState)
          .insert(
            ReviewStateCompanion(
              id: Value(_ri(row, 'id')),
              queue: _vQueueDef(row, 'queue'),
              position: _vIntDef(row, 'position'),
              updatedAt: Value(_ri(row, 'updated_at')),
              // 十四批 M1：会话快照列（D-119）。缺键/NULL 都写 NULL。
              // M2 P1-8 的恢复后会话消失规则另行处理，这里只保值。
              sessionId: Value(_rsN(row, 'session_id')),
              mode: Value(_rsN(row, 'mode')),
              skips: Value(_rsN(row, 'skips')),
              perQuestionState: Value(_rsN(row, 'per_question_state')),
            ),
            mode: InsertMode.insertOrReplace,
          );
    case 'review_history':
      await db
          .into(db.reviewHistory)
          .insert(
            ReviewHistoryCompanion(
              id: row['id'] is int
                  ? Value(row['id'] as int)
                  : const Value.absent(),
              questionId: Value(_rs(row, 'question_id')),
              result: Value(_rs(row, 'result')),
              reviewedAt: Value(_ri(row, 'reviewed_at')),
              // 十四批 M1：新增字段（D-119）。缺键/NULL 都写 NULL；
              // 跨字段一致性由 DDL CHECK 在插库时 enforced。
              causeId: Value(_rsN(row, 'cause_id')),
              sessionId: Value(_rsN(row, 'session_id')),
              reviewMode: Value(_rsN(row, 'review_mode')),
              verdict: Value(_rsN(row, 'verdict')),
              verificationStatus: Value(_rsN(row, 'verification_status')),
              verificationSource: Value(_rsN(row, 'verification_source')),
              attemptId: Value(_rsN(row, 'attempt_id')),
              submissionId: Value(_rsN(row, 'submission_id')),
            ),
            mode: InsertMode.insertOrReplace,
          );
    case 'recent_tasks':
      await db
          .into(db.recentTasks)
          .insert(
            RecentTasksCompanion(
              id: Value(_ri(row, 'id')),
              kind: Value(_rs(row, 'kind')),
              subjectId: Value(_rs(row, 'subject_id')),
              title: Value(_rs(row, 'title')),
              updatedAt: Value(_ri(row, 'updated_at')),
            ),
            mode: InsertMode.insertOrReplace,
          );
    case 'recently_viewed_questions':
      await db
          .into(db.recentlyViewedQuestions)
          .insert(
            RecentlyViewedQuestionsCompanion(
              questionId: Value(_rs(row, 'question_id')),
              viewedAt: Value(_ri(row, 'viewed_at')),
            ),
            mode: InsertMode.insertOrReplace,
          );
    case 'ocr_jobs':
      // 十三批 M2：ocr_jobs 行插库。status / attempt_count 缺键时走
      // Value.absent() 落 DDL 默认值（'pending' / 0）；时间列缺失或
      // 类型不对时 _ri/_riN 抛错（created_at / updated_at 是 NOT NULL
      // 列，不静默默认值）；v2/v3 备份没有 ocr_jobs 键，整表跳过。
      // 十三批 P1-1：lease_token 缺键走 NULL（旧备份的任务行本来就
      // 没有租约；恢复后 running 行由启动时租约回收处理）。
      await db
          .into(db.ocrJobs)
          .insert(
            OcrJobsCompanion(
              id: Value(_rs(row, 'id')),
              questionId: Value(_rs(row, 'question_id')),
              cropPath: Value(_rsN(row, 'crop_path')),
              inputHash: Value(_rsN(row, 'input_hash')),
              status: _vStrDef(row, 'status'),
              attemptCount: _vIntDef(row, 'attempt_count'),
              availableAt: Value(_riN(row, 'available_at')),
              startedAt: Value(_riN(row, 'started_at')),
              leaseUntil: Value(_riN(row, 'lease_until')),
              leaseToken: Value(_rsN(row, 'lease_token')),
              lastErrorCode: Value(_rsN(row, 'last_error_code')),
              lastErrorMessage: Value(_rsN(row, 'last_error_message')),
              createdAt: Value(_ri(row, 'created_at')),
              updatedAt: Value(_ri(row, 'updated_at')),
              completedAt: Value(_riN(row, 'completed_at')),
            ),
            mode: InsertMode.insertOrReplace,
          );
    case 'settings':
      await db
          .into(db.settings)
          .insert(
            SettingsCompanion(
              key: Value(_rs(row, 'key')),
              value: Value(_rs(row, 'value')),
            ),
            mode: InsertMode.insertOrReplace,
          );
    case 'attempts':
      // 十四批 M2：attempts 行插库（P1-6）。answer_version /
      // content_version 原样保留（恢复后历史 attempts 不按新答案
      // 重新判分，版本号不重置）；cause_ids 是原始 JSON 字符串，
      // 缺键/null 走 Value.absent() 落 DDL 默认值 '[]'。
      await db
          .into(db.attempts)
          .insert(
            AttemptsCompanion(
              id: Value(_rs(row, 'id')),
              questionId: Value(_rs(row, 'question_id')),
              sessionId: Value(_rs(row, 'session_id')),
              mode: Value(_rs(row, 'mode')),
              selected: Value(_rsN(row, 'selected')),
              correct: Value(_riN(row, 'correct')),
              confidence: Value(_rsN(row, 'confidence')),
              answerVersion: _vIntDef(row, 'answer_version'),
              contentVersion: _vIntDef(row, 'content_version'),
              status: Value(_rs(row, 'status')),
              causeIds: row.containsKey('cause_ids') &&
                      row['cause_ids'] != null
                  ? Value(_rs(row, 'cause_ids'))
                  : const Value.absent(),
              durationMs: Value(_riN(row, 'duration_ms')),
              // submission_id 在 Drift 表定义里是非空列（TEXT UNIQUE，
              // 无 nullable），缺失/null 直接抛错，不静默默认值。
              submissionId: Value(_rs(row, 'submission_id')),
              createdAt: Value(_ri(row, 'created_at')),
            ),
            mode: InsertMode.insertOrReplace,
          );
    default:
      throw BackupRestoreException('这份备份数据有问题：未知表 $table');
  }
}

/// B3：恢复前清表（类型化版）——`db.delete(...).go()` 按表名分流；
/// 旧写法是 `customUpdate('DELETE FROM $t')`，动态表名拼 SQL。
Future<void> _clearBackupTable(QuizDatabase db, String table) async {
  switch (table) {
    case 'subjects':
      await db.delete(db.subjects).go();
    case 'questions':
      await db.delete(db.questions).go();
    case 'question_boxes':
      await db.delete(db.questionBoxes).go();
    case 'folders':
      await db.delete(db.folders).go();
    case 'tags':
      await db.delete(db.tags).go();
    case 'exams':
      await db.delete(db.exams).go();
    case 'knowledge_points':
      await db.delete(db.knowledgePoints).go();
    case 'cause_records':
      await db.delete(db.causeRecords).go();
    case 'collect_tasks':
      await db.delete(db.collectTasks).go();
    case 'review_state':
      await db.delete(db.reviewState).go();
    case 'review_history':
      await db.delete(db.reviewHistory).go();
    case 'recent_tasks':
      await db.delete(db.recentTasks).go();
    case 'recently_viewed_questions':
      await db.delete(db.recentlyViewedQuestions).go();
    case 'ocr_jobs':
      await db.delete(db.ocrJobs).go();
    case 'attempts':
      await db.delete(db.attempts).go();
    case 'settings':
      await db.delete(db.settings).go();
    default:
      throw BackupRestoreException('这份备份数据有问题：未知表 $table');
  }
}

String _rowLabel(Map<String, Object?> row) =>
    '${row['id'] ?? row['key'] ?? '?'}';

/// 备份行取值助手（B3）：必填列缺失或类型不对时直接抛
/// [BackupRestoreException]（带表内行 id 与列名），不静默默认值、
/// 不猜测转换。调用方 [importBackupJsonIntoImpl] 已先跑过
/// [validateBackupDataImpl]，这里是第二道防线。
String _rs(Map<String, Object?> row, String key) {
  final v = row[key];
  if (v is String) return v;
  throw BackupRestoreException('这份备份数据有问题：${_rowLabel(row)} 行的 $key 缺失或不是文本');
}

String? _rsN(Map<String, Object?> row, String key) {
  final v = row[key];
  if (v == null) return null;
  if (v is String) return v;
  throw BackupRestoreException('这份备份数据有问题：${_rowLabel(row)} 行的 $key 不是文本');
}

// FR-20：只接受 int；带小数的 double 一律拒绝，不静默截断
// （与 D-51“严格取值”一致——之前任何 num 都 toInt()，2.5 会静默存成 2）。
// 整数值 double（如其它工具写出的 2.0）放行：是同一数值的另一种写法，
// 不是猜测转换。
int _ri(Map<String, Object?> row, String key) {
  final v = row[key];
  if (v is int) return v;
  if (v is double && v.truncate() == v) return v.toInt();
  throw BackupRestoreException('这份备份数据有问题：${_rowLabel(row)} 行的 $key 缺失或不是整数');
}

int? _riN(Map<String, Object?> row, String key) {
  final v = row[key];
  if (v == null) return null;
  if (v is int) return v;
  if (v is double && v.truncate() == v) return v.toInt();
  throw BackupRestoreException('这份备份数据有问题：${_rowLabel(row)} 行的 $key 不是整数');
}

double _rd(Map<String, Object?> row, String key) {
  final v = row[key];
  if (v is num) return v.toDouble();
  throw BackupRestoreException('这份备份数据有问题：${_rowLabel(row)} 行的 $key 缺失或不是数字');
}

double? _rdN(Map<String, Object?> row, String key) {
  final v = row[key];
  if (v == null) return null;
  if (v is num) return v.toDouble();
  throw BackupRestoreException('这份备份数据有问题：${_rowLabel(row)} 行的 $key 不是数字');
}

/// 有 DDL 默认值的可选列：键缺失时走 `Value.absent()`（落库默认值，
/// 与旧写法“缺键不写”同口径）；键在但类型不对时仍抛错。
Value<String> _vStrDef(Map<String, Object?> row, String key) =>
    row.containsKey(key) ? Value(_rs(row, key)) : const Value.absent();

Value<int> _vIntDef(Map<String, Object?> row, String key) =>
    row.containsKey(key) ? Value(_ri(row, key)) : const Value.absent();

/// FR-21：JSON 列缺键时也走 `Value.absent()`（落库 DDL 默认值，
/// 与旧写法“缺键不写”同口径）；键在时才走 decode → Value。
/// 之前是无条件 `Value(decode(...))`，缺键行恢复后存成 `'[]'`/`'{}'`，
/// 与旧口径的 `''`（page_rotations 缺键时新旧一致，都是 `'{}'`）漂移
/// （语义等价，仅存储表示不同）。
Value<List<String>> _vStringListDef(Map<String, Object?> row, String key) =>
    row.containsKey(key)
    ? Value(AppDatabase.decodeStringList(row[key]))
    : const Value.absent();

Value<List<ReviewQueueItem>> _vQueueDef(Map<String, Object?> row, String key) =>
    row.containsKey(key)
    ? Value(AppDatabase.decodeQueue(row[key]))
    : const Value.absent();

Value<Map<int, int>> _vRotationsDef(Map<String, Object?> row, String key) =>
    row.containsKey(key)
    ? Value(AppDatabase.decodeRotations(row[key]))
    : const Value.absent();

/// B4.2：恢复（可单测版）。
/// SR-P2-4：插库时的残余异常统一包成 [BackupRestoreException]
/// （文案写“备份数据有问题”）：校验已拦住大多数非法行，但列名
/// 不在表里、值超约束等仍可能在插库时才抛原生数据库异常，
/// 旧写法会把 sqlite 原文直接展示给用户。
/// （Drift 下原生错误是 SqliteException / DriftWrappedException，
/// 不再是 sqflite 的 DatabaseException；try 块里只有数据库操作，
/// 故按 [Exception] 兜底，不再按单一异常类型收。）
Future<void> importBackupJsonIntoImpl(
  QuizDatabase db,
  Map<String, dynamic> data,
) async {
  AppDatabase.validateBackupData(data);
  final clearOrder = <String>[
    'question_boxes',
    ...AppDatabase.backupTables.reversed.where((t) => t != 'question_boxes'),
  ];
  try {
    await db.transaction(() async {
      for (final t in clearOrder) {
        await _clearBackupTable(db, t);
      }
      for (final t in AppDatabase.backupTables) {
        // 十四批 M2（P1-6）：备份不含未完成会话——review_state 已在
        // 上面清掉，备份里的行（v4 及更早备份可能带会话快照；v5 备份
        // 导出为 []）一律不插；恢复完成后不创建任何活动会话。
        if (t == 'review_state') continue;
        final rows = data[t];
        if (rows is! List) continue;
        for (final row in rows) {
          if (row is! Map) continue;
          await _backupInsertRowTyped(db, t, Map<String, Object?>.from(row));
        }
      }
      // §2.3：恢复后 settings.schemaVersion 写回当前版本
      // （AppDatabase.schemaVersion；备份里的 settings 行若缺这一键，
      // 在此补写；若有，也以当前版本为准）。
      // B2：走 db_settings 的类型化 upsert（db.into(db.settings)，
      // 不再手写 INSERT OR REPLACE SQL；与事务同连接，失败随事务回滚）。
      await _upsertSettingInto(
        db,
        'schemaVersion',
        '${AppDatabase.schemaVersion}',
      );
    });
  } on BackupRestoreException {
    rethrow;
  } on Exception catch (e) {
    // 事务已回滚，原库不动；只换文案，不吞错因。
    throw BackupRestoreException('这份备份数据有问题，恢复失败：$e');
  }
}

/// §2.3/P3：zip 文件级备份（`backup.json` + `imports/` + `slices/`）。
/// 只打包库里引用到的文件（questions 的 source_path /
/// page_image_path / slice_path + ocr_figures 里的 crop_path（十四批 M2）
/// + collect_tasks 的 source_path）；无引用的孤儿文件不进备份。
/// 缺文件（路径在库里、文件不在盘上）不进包，恢复后该题走“图片缺失”，
/// 不静默造假文件。旧入口：警告丢弃（设置页走带报告的新入口）。
Future<List<int>> exportBackupZipFromImpl(
  QuizDatabase db, {
  String? dataDir,
}) async {
  final report = await exportBackupZipFromWithReportImpl(
    db,
    dataDir: dataDir,
  );
  return report.bytes;
}

/// 图块裁图字节是否可解码（PNG；写盘时由 cropFigurePng 编码）。
/// 解不出/截断/损坏 → false。只用于备份导出与恢复校验，
/// 不抛错（不可读按“坏图”处理，不阻断整库备份/恢复）。
bool _decodableFigureBytes(List<int> bytes) {
  try {
    return img.decodeImage(Uint8List.fromList(bytes)) != null;
  } catch (_) {
    return false;
  }
}

/// 十四批 M2（P1-6 + P1-B）：带警告的 zip 备份。
/// - 导出器从每题 ocr_figures JSON 提取每个有效 crop_path 显式加入
///   ZIP 清单（`_referencedRelativePaths` 已含图块裁图；目录白名单只
///   决定“允许进入 ZIP”，不等于自动归档——这里按清单逐个加入）。
/// - 备份只读暂存区副本，绝不直接读原文件：锁内快照文件清单 → 复制
///   到数据目录下独立暂存区 `.backup-staging-<时间戳>` → 登记暂存占用
///   → 释锁 → 从暂存区读文件建 ZIP → 成功/失败后都删暂存区并解除占用。
///   锁只在快照复制期间持有；ZIP 构建在释锁后进行。
/// - 十四批 M5 修复轮 2（B-FIX2-1）：同一逻辑时点快照——JSON 导出、
///   文件引用集合读取与图块→题目映射在**同一个数据库事务**
///   （Drift 事务为 BEGIN IMMEDIATE，同一连接上串行化）内完成，
///   且整个事务 + 暂存区复制都在**同一文件锁**内。只把导出移进锁
///   是不够的：删题的数据库提交本就不取文件锁，若 JSON 与引用集合
///   不在同一 DB 快照里，删题提交仍可插在两者之间。本协议下，删题
///   提交若发生在快照事务之前，题与文件都不进备份；若发生在快照
///   事务之后、暂存复制完成之前，题进 JSON，但删题的物理删文件
///   必须取文件锁（见 `_deleteDataFileIfUnreferenced` 与孤儿清理），
///   而备份此时仍持锁，删文件排队等待，文件在复制完成前不会消失；
///   复制完成后登记暂存占用，删文件路径见占用即跳过。
///   文件复制不放进 DB 事务：IO 复制持 BEGIN IMMEDIATE 写锁会长
///   时间阻塞写事务；文件锁已足以挡住物理删除，DB 事务只覆盖
///   “读快照”这一小段。
/// - 导出前逐个验证引用文件存在、可读：库行直接引用的资产（题目
///   的 source_path / page_image_path / slice_path / 图块裁图、
///   收集任务的 source_path、识别任务的 crop_path）缺失或无法读取
///   时备份直接失败（BackupRestoreException，指明题目/任务 ID 与
///   相对路径），不生成看似成功实际不完整的备份；派生文件
///   （任务的 page-normalized.png、pages/ 下页图、original.* 枚举）
///   只在快照时点文件存在时才进清单（二十批 P6 修法 A，D-237 提案）——
///   按构造从未生成的文件本来就不在清单里，不警告、不变 partial；
///   快照时已在盘上的派生文件在复制/组装阶段缺失/不可读时逐项警告、
///   不阻断备份。这不复活 D-155 已废止的旧口径：门禁只作用于 JSON
///   从不引用的派生文件，直接引用缺失仍整单抛错。图块损坏
///   （读得出但解不出图）仍只警告、不阻断。
///   十四批 M5 修复轮 3（D-155）：旧口径“非图块文件缺失静默不进包”
///   已废止——它与备份不变量（JSON 引用的文件都应在 ZIP 中）冲突。
///   十四批 M5 修复轮 4（D-159/D-160）：释锁后 ZIP 组装阶段暂存区
///   文件缺失/读取失败也按同一分类处理（图块警告、直接引用失败、
///   派生警告）；派生文件路径非法时记 warning，不再静默跳过。
///   十四批 M5 修复轮 5（D-162）：引用集入口 fail-closed——
///   `_toDataRelative` 无法归一化的库内存引用（越出数据目录/
///   数据目录外绝对路径）不再直接丢弃，备份专用的非法引用收集
///   （见 [_BackupIllegalRef]）在锁内快照时保留原始路径、归属与
///   类别；关键直接引用非法即抛错终止备份，图块/派生非法只记
///   warning；归一化后仍在数据目录内的 `..`（如
///   `slices/../slices/q1.png`）是合法的，按原规则正常处理。
///   孤儿扫描与恢复复核仍走 `_directlyReferencedRelativePaths` /
///   `_referencedRelativePaths` 原语义，本收集只供备份用。
///   finally 里暂存占用注销放进内层 finally（D-161）。
/// 返回 ZIP 字节与警告列表（空即无警告）。

/// 十四批 M5 修复轮 5（D-162）：备份完整性检查用的非法引用记录。
/// 只供备份导出用；孤儿扫描与恢复复核不走这里，不改变
/// [_directlyReferencedRelativePaths] / [_referencedRelativePaths]
/// 的语义（GPT fix4 修法第 4 条）。
/// - [raw]：库里存的原始引用路径（未归一化，警告/异常里原样列出）；
/// - [owner]：归属文案（题目「id」/收集任务「id」）；
/// - [kind]：引用类别——direct（题目切片等关键直接引用）、
///   figure（图块裁图）、derived（任务派生文件）；
/// - [figureTitle]：图块所属题目的标题（仅 kind == figure 时用，
///   警告文案沿用既有图块口径列出题目）；
/// - [reason]：非法原因（越出数据目录 / 数据目录外绝对路径 /
///   归一化后不在 imports/ 或 slices/ 下）。
enum _BackupIllegalRefKind { direct, figure, derived }

typedef _BackupIllegalRef = ({
  String raw,
  String owner,
  _BackupIllegalRefKind kind,
  String? figureTitle,
  String reason,
});

/// WP-C #8 U3-2：备份完整性状态。
/// [complete] 仅当零警告且零 BROKEN 文件；任一文件未进包即 [partial]，
/// 永不静默记 COMPLETE。库行直接引用缺失/不可读时整单抛错、不生成
/// 备份（D-155 fail-closed），那种情况没有备份可记状态，不在此枚举。
enum BackupExportStatus { complete, partial }

/// 二十批 P6 修法 A（D-237 提案）：派生引用只在文件存在时枚举。
///
/// Q4 的逐类打补丁（`_isOptionalNormalized`：source_path 前缀 / PDF 后缀 /
/// 状态 / EXIF 方向 / source_hash 复核）已随修法 A 删除——存在性门禁在
/// 枚举阶段一次解决“按构造不该有”这一整类误报，不再逐类判定。门禁落点在
/// [exportBackupZipFromWithReportImpl] 的锁内快照之后、复制循环之前：
/// 引用集里除直接引用与图块裁图之外的派生路径，在快照时点逐个查存在性，
/// 不在盘上的直接从备份清单里去掉，不警告、不进 brokenFiles、不变 partial。
/// 直接引用（缺失仍整单抛错，D-155）与图块裁图（缺失仍警告，D-158）
/// 不受门禁影响。门禁在同一锁内完成，枚举与复制之间插不进进程内删除；
/// 孤儿保护仍用 [_referencedRelativePaths] 原语义（行存在即保护），
/// 本门禁只作用于备份清单，不动 `db_orphans.dart`。
///
/// 有意的取舍：EXIF 方向 3/6/8 且哈希可信、但归一化副本缺失的情形，
/// Q4 曾记一条注明歧义的警告（O2）；修法 A 下它不再警告。理由：
/// (1) 该信号本身有歧义——真丢失与当初静默降级未生成在现有数据下
/// 完全同构（`import_service.dart:700-720`，Q4 调查 §2.5）；
/// (2) 归一化副本可由原图再生，而原图是直接引用、缺失即整单抛错，
/// 备份里不丢任何不可替代的数据；显示时无副本回落到原图。
/// 快照时已在盘上的派生文件若在复制/组装阶段丢失，仍按通用派生口径
/// 警告（见复制循环与 ZIP 组装循环的派生分支）。

Future<({List<int> bytes, List<String> warnings, List<String> brokenFiles, BackupExportStatus status})>
exportBackupZipFromWithReportImpl(
  QuizDatabase db, {
  String? dataDir,
  /// 仅测试用：释锁后、ZIP 组装循环前调用一次的故障注入钩子，
  /// 用于删/换暂存区里的文件以验证 P1-1 分类（D-159）。生产调用
  /// 不传。钩子只应改动 stagingDir 内的文件，不得改 stagedRels
  /// 清单本身；钩子抛异常按导出失败处理（finally 仍清理暂存区）。
  void Function(Directory stagingDir, List<String> stagedRels)?
  onStagedForTest,
}) async {
  final dir = dataDir ?? AppDatabase.dataDirectoryPath();
  final guard = FileLifecycleGuard.instance;
  final warnings = <String>[];
  // WP-C #8 U3-2：未进包的文件清单（BROKEN）——函数作用域（与
  // warnings 同级），锁内复制循环与释锁后 ZIP 组装循环都要往里记。
  final brokenFiles = <String>{};
  final stagedRels = <String>[];
  var stagingDir = Directory('');
  // 同一逻辑时点的快照结果（JSON + 引用集合 + 图块→题目映射），
  // 在锁内由单一 DB 事务产出；ZIP 构建在释锁后用它建。
  var json = '';
  // 十四批 M5 修复轮 4（D-159）：锁内快照产出的分类集合也提升到
  // withLock 闭包外的作用域（与 json 的提升写法一致），使释锁后
  // 的 ZIP 组装循环能按同一分类处理暂存区缺失/读取失败。
  var directRefs = <String>{};
  var figureQuestions = <String, String>{};
  var assetOwners = <String, String>{};
  // 十四批 M5 修复轮 5（D-162）：锁内快照产出的非法引用收集也提升
  // 到 withLock 闭包外（与 directRefs 等一致），使释锁前的完整性
  // 检查能用同一快照的分类。
  var illegalRefs = <_BackupIllegalRef>[];
  try {
    await guard.withLock(() async {
      // 同一 DB 事务内完成 JSON 导出、引用集合读取与图块映射——
      // 三者来自同一个数据库快照，中间插不进并发删题提交。
      final snapshot = await db.transaction(() async {
        final snapshotJson = await exportBackupJsonFromImpl(db);
        final refs = await _referencedRelativePaths(db, dir);
        // 十四批 M5 修复轮 3（D-155）：库行直接引用的资产集合——与
        // 派生保护（任务的 page-normalized.png、pages/ 下页图、
        // original.* 枚举）区分开：直接引用缺失/不可读即备份失败，
        // 派生文件缺失/不可读只逐项警告（未渲染过的任务本来就没有
        // 派生文件，失败会误伤正常备份）。
        final directRefs = await _directlyReferencedRelativePaths(db, dir);
        // 图块裁图 → 题目（警告文案列出题目）。
        final figureQuestions = <String, String>{};
        // 直接引用资产 → 归属文案（失败信息里指明题目/任务 ID 与相对路径）。
        final assetOwners = <String, String>{};
        // 十四批 M5 修复轮 5（D-162，GPT fix4 §7 P1）：备份专用的
        // 非法引用收集——与 _directlyReferencedRelativePaths /
        // _referencedRelativePaths 并行走同一批库行，但保留
        // _toDataRelative 返回 null 的引用（原始路径、归属、类别、
        // 原因），不让它们在引用集入口被静默丢弃。孤儿扫描与恢复
        // 复核仍用原函数原语义，本收集只供备份完整性检查用。
        // 合法性判定与 _toDataRelative 同口径：归一化后仍在数据
        // 目录内即合法（含内部 `..`，如 `slices/../slices/q1.png`
        // → `slices/q1.png`，按原规则正常处理，不记非法）；只有
        // 越出数据目录、或数据目录外的绝对路径才算非法。
        final illegalRefs = <_BackupIllegalRef>[];
        void checkStored(
          String? stored,
          String owner,
          _BackupIllegalRefKind kind, {
          String? figureTitle,
        }) {
          if (stored == null || stored.isEmpty) return;
          if (_toDataRelative(stored, dir) != null) return;
          illegalRefs.add((
            raw: stored,
            owner: owner,
            kind: kind,
            figureTitle: figureTitle,
            reason: p.isAbsolute(stored)
                ? '绝对路径不在数据目录内'
                : '路径越出数据目录',
          ));
        }

        // 派生非法：任务 id 本身含 `..` 等穿越段时，构造出的派生
        // 路径归一化后会落在任务目录之外（任务 id `..` 时
        // `imports/../page-normalized.png` → 数据目录根的
        // `page-normalized.png`）。构造派生路径不可能越出数据
        // 目录本身（_toDataRelative 不会返回 null），故派生非法
        // 的判定是“归一化后不在 imports/ 或 slices/ 白名单内”。
        // 与 _referencedRelativePaths 的派生枚举同口径：构造的
        // page-normalized、pages/ 下现存文件、original.* 现存文件。
        // 同一原始路径只记一次。
        final seenDerivedRaw = <String>{};
        void checkDerived(String raw, String taskLabel) {
          if (!seenDerivedRaw.add(raw)) return;
          final rel = _toDataRelative(raw, dir);
          if (rel != null &&
              (rel.startsWith('imports/') || rel.startsWith('slices/'))) {
            return;
          }
          illegalRefs.add((
            raw: raw,
            owner: taskLabel,
            kind: _BackupIllegalRefKind.derived,
            figureTitle: null,
            reason: rel == null
                ? '路径越出数据目录'
                : '路径归一化后不在 imports/ 或 slices/ 下',
          ));
        }

        void own(String? stored, String label) {
          if (stored == null || stored.isEmpty) return;
          final rel = _toDataRelative(stored, dir);
          if (rel != null) assetOwners.putIfAbsent(rel, () => label);
        }

        // WP-C #8 U3-2：本快照内任一题的 ocrFigures JSON 是否无法解析
        // （引用未知）。与图块映射同一时点判定，见 questions 循环内。
        var unknownFigureRefs = false;
        for (final row in await db.select(db.questions).get()) {
          // WP-C #8 U3-2：与快照同一时点判定引用是否未知——有题的
          // ocrFigures JSON 无法解析时，图块可能未进备份，只记警告
          // （不阻断）、状态记 PARTIAL。
          if (_ocrFiguresJsonIsUnknown(row.ocrFigures)) {
            unknownFigureRefs = true;
          }
          for (final crop in _figureCropPathsFromJson(row.ocrFigures)) {
            figureQuestions.putIfAbsent(crop, () => row.title);
            assetOwners.putIfAbsent(crop, () => '题目「${row.id}」');
            checkStored(
              crop,
              '题目「${row.id}」',
              _BackupIllegalRefKind.figure,
              figureTitle: row.title,
            );
          }
          own(row.sourcePath, '题目「${row.id}」');
          checkStored(
            row.sourcePath,
            '题目「${row.id}」',
            _BackupIllegalRefKind.direct,
          );
          own(row.pageImagePath, '题目「${row.id}」');
          checkStored(
            row.pageImagePath,
            '题目「${row.id}」',
            _BackupIllegalRefKind.direct,
          );
          own(row.slicePath, '题目「${row.id}」');
          checkStored(
            row.slicePath,
            '题目「${row.id}」',
            _BackupIllegalRefKind.direct,
          );
        }
        for (final row in await db.select(db.collectTasks).get()) {
          own(row.sourcePath, '收集任务「${row.id}」');
          checkStored(
            row.sourcePath,
            '收集任务「${row.id}」',
            _BackupIllegalRefKind.direct,
          );
          // 派生非法检查：任务 id 含分隔符时 _referencedRelativePaths
          // 本来就跳过派生口径，这里同口径跳过（防止 p.join 被带出
          // imports/<taskId>/）；`..` 不含分隔符，会走到这里。
          final taskId = row.id;
          final taskLabel = '收集任务「$taskId」';
          if (taskId.isNotEmpty &&
              !taskId.contains('/') &&
              !taskId.contains('\\')) {
            checkDerived('imports/$taskId/page-normalized.png', taskLabel);
            final pagesDir = Directory(
              p.join(dir, 'imports', taskId, 'pages'),
            );
            if (pagesDir.existsSync()) {
              for (final e in pagesDir.listSync()) {
                if (e is! File) continue;
                checkDerived(
                  'imports/$taskId/pages/${p.basename(e.path)}',
                  taskLabel,
                );
              }
            }
            final taskDir = Directory(p.join(dir, 'imports', taskId));
            if (taskDir.existsSync()) {
              for (final e in taskDir.listSync()) {
                if (e is! File) continue;
                final name = p.basename(e.path);
                if (name == 'original' || name.startsWith('original.')) {
                  checkDerived('imports/$taskId/$name', taskLabel);
                }
              }
            }
          }
        }
        for (final row in await db.select(db.ocrJobs).get()) {
          own(row.cropPath, '题目「${row.questionId}」');
          checkStored(
            row.cropPath,
            '题目「${row.questionId}」',
            _BackupIllegalRefKind.direct,
          );
        }
        return (
          json: snapshotJson,
          refs: refs,
          directRefs: directRefs,
          figureQuestions: figureQuestions,
          assetOwners: assetOwners,
          illegalRefs: illegalRefs,
          unknownFigureRefs: unknownFigureRefs,
        );
      });
      json = snapshot.json;
      final refs = snapshot.refs;
      directRefs = snapshot.directRefs;
      figureQuestions = snapshot.figureQuestions;
      assetOwners = snapshot.assetOwners;
      illegalRefs = snapshot.illegalRefs;
      // WP-C #8 U3-2：引用未知 → 图块可能未进备份，只记警告、不阻断。
      if (snapshot.unknownFigureRefs) {
        warnings.add('有题目的配图引用无法解析（配图数据损坏），配图可能未包含在备份中');
      }
      // 十四批 M5 修复轮 5（D-162）：非法引用完整性检查——在复制
      // 循环前、锁内执行，失败发生在建暂存区之前，不产生待复制文件，
      // finally 只需清空登记（暂存区尚未创建）。
      // 分类处理（与锁内复制阶段、ZIP 组装阶段同一优先级，图块优先）：
      // 关键直接引用非法 → 抛 BackupRestoreException 终止备份
      // （D-155 fail-closed；失败信息含归属与原始路径）；
      // 图块裁图非法 → warning（列出题目与原始路径，D-158）；
      // 派生文件非法 → warning（列出归属任务与原始路径）。
      // 同一原始路径既是图块裁图又是题目切片时按切片角色处理：
      // 切片不可再生，图块可从切片 + bbox 再生，故直接引用抛错优先。
      final illegalDirect = illegalRefs
          .where((r) => r.kind == _BackupIllegalRefKind.direct)
          .toList();
      if (illegalDirect.isNotEmpty) {
        final bad = illegalDirect.first;
        throw BackupRestoreException(
          '备份失败：${bad.owner} 的文件路径非法（${bad.raw}），备份未生成',
        );
      }
      for (final bad in illegalRefs.where(
        (r) => r.kind == _BackupIllegalRefKind.figure,
      )) {
        warnings.add(
          '题目「${bad.figureTitle ?? bad.owner}」的配图路径非法（${bad.raw}），未包含在备份中',
        );
        brokenFiles.add(bad.raw);
      }
      for (final bad in illegalRefs.where(
        (r) => r.kind == _BackupIllegalRefKind.derived,
      )) {
        warnings.add('${bad.owner}的派生文件 ${bad.raw} 路径非法，未包含在备份中');
        brokenFiles.add(bad.raw);
      }
      // 二十批 P6 修法 A（D-237 提案）：派生引用只在文件存在时枚举——
      // 锁内快照之后、复制循环之前，对引用集做存在性门禁：除直接引用
      // 与图块裁图之外的派生路径（构造的 page-normalized.png，以及
      // pages/ 与 original.* 的现存枚举），在此时点不在盘上的直接
      // 从备份清单里去掉，不警告、不进 brokenFiles、不变 partial。
      // 门禁放在锁内：枚举与复制在同一锁内完成，通过门禁的文件在复制
      // 前不会被进程内删除者删掉；直接引用与图块裁图不受门禁影响
      // （前者缺失仍整单抛错 D-155，后者缺失仍警告 D-158）。
      // 路径本身无法解析（_resolveInsideDir 为 null）的不由门禁处理，
      // 留给复制循环按 D-162 派生非法记警告。
      final backupRefs = refs.where((rel) {
        if (directRefs.contains(rel)) return true;
        if (figureQuestions.containsKey(rel)) return true;
        final abs = _resolveInsideDir(dir, rel);
        if (abs == null) return true;
        return File(abs).existsSync();
      }).toSet();
      final sorted = backupRefs.toList()..sort();
      // 暂存区名取毫秒时间戳；同毫秒已存在时 +1（仍是纯数字，
      // 符合启动清理的严格匹配规则；建目录在锁内，无竞态）。
      var ts = DateTime.now().millisecondsSinceEpoch;
      while (Directory(
        p.join(dir, FileLifecycleGuard.backupStagingDirName(ts)),
      ).existsSync()) {
        ts++;
      }
      stagingDir = Directory(
        p.join(dir, FileLifecycleGuard.backupStagingDirName(ts)),
      );
      await stagingDir.create(recursive: true);
      for (final rel in sorted) {
        if (!rel.startsWith('imports/') && !rel.startsWith('slices/')) {
          continue;
        }
        final abs = _resolveInsideDir(dir, rel);
        // 十四批 M5 修复轮 3（D-155，GPT fix2 P1-2；D-158 修正）：
        // 所有直接引用的资产统一处理缺失与读取失败，不只对图块告警。
        // 关键资产（库行直接引用，尤其 slice_path）缺失/不可读即备份
        // 失败，失败信息指明归属与相对路径；只在派生保护里的文件缺失/
        // 不可读时逐项警告、不阻断备份。例外：图块裁图缺失/不可读/
        // 路径非法时只警告、不阻断（D-158：图块可从切片 + bbox 再生，
        // M2 P1-6 既定口径“单个图块失败不阻断备份”；警告须列出题目）。
        final isDirect = directRefs.contains(rel);
        final owner = assetOwners[rel] ?? rel;
        final isFigure = figureQuestions.containsKey(rel);
        if (abs == null) {
          if (isFigure) {
            warnings.add('题目「${figureQuestions[rel]}」的配图路径非法，未包含在备份中');
            brokenFiles.add(rel);
            continue;
          }
          if (isDirect) {
            throw BackupRestoreException(
              '备份失败：$owner 的文件路径非法（$rel），备份未生成',
            );
          }
          // 十四批 M5 修复轮 4（D-160，GPT fix3 P1-2）：派生文件路径
          // 无法解析也不再静默跳过，记 warning、继续导出（文案与
          // “派生文件 $rel 缺失/无法读取，未包含在备份中”体系统一）。
          warnings.add('派生文件 $rel 路径非法，未包含在备份中');
          brokenFiles.add(rel);
          continue;
        }
        final f = File(abs);
        if (!f.existsSync()) {
          if (isFigure) {
            warnings.add('题目「${figureQuestions[rel]}」的配图缺失，未包含在备份中');
            brokenFiles.add(rel);
            continue;
          }
          if (isDirect) {
            throw BackupRestoreException(
              '备份失败：$owner 的文件缺失（$rel），备份未生成',
            );
          }
          // 二十批 P6 修法 A：派生文件在快照时已通过存在性门禁才进
          // 清单，复制时缺失说明它在快照后丢了（门禁与复制同一锁内，
          // 进程内删除插不进来，只剩锁外删除者），按通用派生口径警告。
          warnings.add('派生文件 $rel 缺失，未包含在备份中');
          brokenFiles.add(rel);
          continue;
        }
        List<int> bytes;
        try {
          bytes = await f.readAsBytes();
        } catch (_) {
          if (isFigure) {
            warnings.add('题目「${figureQuestions[rel]}」的配图无法读取，未包含在备份中');
            brokenFiles.add(rel);
            continue;
          }
          if (isDirect) {
            throw BackupRestoreException(
              '备份失败：$owner 的文件无法读取（$rel），备份未生成',
            );
          }
          warnings.add('派生文件 $rel 无法读取，未包含在备份中');
          brokenFiles.add(rel);
          continue;
        }
        if (isFigure && !_decodableFigureBytes(bytes)) {
          warnings.add('题目「${figureQuestions[rel]}」的配图已损坏，未包含在备份中');
          brokenFiles.add(rel);
          continue;
        }
        final dest = File(p.join(stagingDir.path, rel));
        await dest.parent.create(recursive: true);
        await dest.writeAsBytes(bytes);
        stagedRels.add(rel);
      }
      // 登记暂存区占用：快照复制期间与释锁后读暂存区期间，
      // 其它删除路径不得删这些原文件（删题/孤儿清理在锁内见占用即跳过）。
      guard.registerStaging(stagedRels);
    });
    // 释锁后从暂存区读文件建 ZIP——绝不直接读原文件。
    // 十四批 M5 修复轮 4（D-159，GPT fix3 P1-1）：暂存区文件缺失或
    // 读取失败不再无条件跳过，按与锁内复制阶段一致的分类处理——
    // 先判图块（只警告）、再判直接引用（抛错）、最后派生（警告）。
    // 图块即使同时在 directRefs 里也只警告不阻断（D-158）。
    // 仅测试用的故障注入钩子在循环前调用一次（见 onStagedForTest）。
    onStagedForTest?.call(stagingDir, stagedRels);
    final entries = <ZipEntryData>[
      ZipEntryData('backup.json', utf8.encode(json)),
    ];
    for (final rel in stagedRels) {
      final staged = File(p.join(stagingDir.path, rel));
      final isFigure = figureQuestions.containsKey(rel);
      final isDirect = directRefs.contains(rel);
      final owner = assetOwners[rel] ?? rel;
      if (!staged.existsSync()) {
        if (isFigure) {
          warnings.add('题目「${figureQuestions[rel]}」的配图暂存区文件缺失，未包含在备份中');
          brokenFiles.add(rel);
          continue;
        }
        if (isDirect) {
          throw BackupRestoreException(
            '备份失败：$owner 的暂存区文件缺失（$rel），备份未生成',
          );
        }
        // 二十批 P6 修法 A：进暂存区即通过了快照时点的存在性门禁，
        // 暂存区丢失是真实丢失，按通用派生口径警告（不再按 Q4 分类
        // 静默跳过——快照时在盘上的文件本就该进包）。
        warnings.add('派生文件 $rel 暂存区文件缺失，未包含在备份中');
        brokenFiles.add(rel);
        continue;
      }
      List<int> bytes;
      try {
        bytes = await staged.readAsBytes();
      } catch (_) {
        if (isFigure) {
          warnings.add('题目「${figureQuestions[rel]}」的配图暂存区文件无法读取，未包含在备份中');
          brokenFiles.add(rel);
          continue;
        }
        if (isDirect) {
          throw BackupRestoreException(
            '备份失败：$owner 的暂存区文件无法读取（$rel），备份未生成',
          );
        }
        warnings.add('派生文件 $rel 暂存区文件无法读取，未包含在备份中');
        brokenFiles.add(rel);
        continue;
      }
      entries.add(ZipEntryData(rel, bytes));
    }
    // WP-C #8 U3-2：BROKEN 清单去重排序；状态永不静默记 COMPLETE——
    // 任一警告或任一 BROKEN 文件即 PARTIAL。
    final broken = brokenFiles.toList()..sort();
    final status = (warnings.isEmpty && broken.isEmpty)
        ? BackupExportStatus.complete
        : BackupExportStatus.partial;
    return (
      bytes: buildZip(entries),
      warnings: warnings,
      brokenFiles: broken,
      status: status,
    );
  } finally {
    // 成功/失败后都删暂存区并解除占用（崩溃残留由启动清理处理）。
    // 十四批 M2（P2-2）：暂存区删除也经统一文件操作锁。
    // 十四批 M5 修复轮 4（D-161，GPT fix3 非阻断观察）：注销放进
    // 内层 finally——删目录失败也不跳过注销；删目录失败按
    // best-effort 吞掉，不掩盖主流程的成功/失败。残留目录由启动时
    // cleanupStaleBackupStagingDirs 清理（严格匹配
    // `.backup-staging-<纯数字>`）。注意现实现里 deleteDirectory
    // 经 deleteDirectoryLocked，内部已吞掉删除异常，删目录抛错
    // 目前只在 withLock 本身失败时才可能发生；这里是纵深防御，
    // 不依赖该现状。
    try {
      if (stagingDir.path.isNotEmpty) {
        try {
          await FileLifecycleGuard.instance.deleteDirectory(stagingDir);
        } catch (_) {
          // best-effort：暂存区删不掉只留磁盘残留，不掩盖主流程结果。
        }
      }
    } finally {
      guard.unregisterStaging(stagedRels);
    }
  }
}

List<ZipEntryData> _readZipOrThrow(List<int> bytes, {int? maxTotalBytes}) {
  try {
    return maxTotalBytes == null
        ? readZip(bytes)
        : readZip(bytes, maxTotalBytes: maxTotalBytes);
  } on ZipFormatException catch (e) {
    throw BackupRestoreException('这份备份文件已损坏：${e.message}');
  }
}

Map<String, dynamic> _decodeBackupJson(List<int> bytes) {
  dynamic decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } catch (_) {
    throw BackupRestoreException('这份备份文件已损坏：题目数据不是合法 JSON');
  }
  if (decoded is! Map<String, dynamic>) {
    throw BackupRestoreException('这份备份文件已损坏：题目数据格式不对');
  }
  AppDatabase.validateBackupData(decoded);
  return decoded;
}

/// §2.3/P3：从 zip 备份里读出 JSON（只读 `backup.json`，不解文件），
/// 供设置页“选完文件先确认”时预览题数与版本校验。
/// 不是 zip / 缺 backup.json / JSON 非法 / 版本校验不过 → 抛
/// BackupRestoreException（带具体原因），原库不动。
Map<String, dynamic> readBackupJsonFromZipImpl(List<int> bytes) {
  final entries = _readZipOrThrow(bytes, maxTotalBytes: maxBackupFileBytes);
  ZipEntryData? jsonEntry;
  for (final e in entries) {
    if (e.name == 'backup.json') jsonEntry = e;
  }
  if (jsonEntry == null) {
    throw BackupRestoreException('这份备份里没有题目数据（缺少 backup.json）');
  }
  return _decodeBackupJson(jsonEntry.bytes);
}

/// SR-P2-5：§6 第 9 条的 2GB 存储上限（与
/// [ImportService.maxStorageBytes] 同一值；database.dart 不能 import
/// import_service，会循环依赖，故在此另列常量）。
/// 备份恢复是另一条进数据的路：旧写法全程无容量检查，恢复一个 3GB
/// 的 zip 会直接把库撑过 2GB。JSON 恢复不产生新文件（只换库内行），
/// 不适用此检查；zip 恢复在文件进位前估算，超了拒绝整个恢复。
const int _maxRestoreBytes = 2 * 1024 * 1024 * 1024;

/// B 包 P1-04：备份文件本身（压缩后的 zip / JSON）上限 200MB。
/// 在 readAsBytes 之前检查，避免把超大文件整体读进内存；zip 解压
/// 后的总量也复用同一上限（见 [readBackupJsonFromZipImpl] /
/// [importBackupZipIntoImpl]），比原来的 2GB/4GB 低得多。
const int maxBackupFileBytes = 200 * 1024 * 1024;

/// SR-P2-5：数据目录下 imports/ + slices/ 的当前占用字节数
/// （与 ImportService.storageUsageBytes 同一口径，但按传入的
/// [dir] 算——恢复测试传临时目录，不能读真实数据目录）。
Future<int> _dataDirFileUsageBytes(String dir) async {
  var total = 0;
  for (final sub in ['imports', 'slices']) {
    final d = Directory(p.join(dir, sub));
    if (!d.existsSync()) continue;
    await for (final e in d.list(recursive: true)) {
      if (e is File) {
        try {
          total += await e.length();
        } catch (_) {}
      }
    }
  }
  return total;
}

/// FR-42：恢复峰值估算里的数据库快照大小——当前库文件 + 已有 -wal/-shm
/// （快照是整库拷贝，恢复中与原库共存；不存在的文件不计）。
int _restoreSnapshotBytes(String dir) {
  var total = 0;
  final dbPath = p.join(dir, 'quiz-master2.db');
  for (final path in [dbPath, '$dbPath-wal', '$dbPath-shm']) {
    try {
      final f = File(path);
      if (f.existsSync()) total += f.lengthSync();
    } catch (_) {}
  }
  return total;
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

/// SR-P2-6：旧恢复 staging 目录的严格匹配（与
/// [_deleteStaleMigrationStaging] 的 B2-5d 同一口径）：
/// 名字必须是 `.restore-staging-<纯数字时间戳>`；形如
/// `.restore-staging-backup` 的用户目录一概不动。
/// 旧写法只认前缀 `.restore-staging-`，数据目录下一个同名用户
/// 目录会被误删。
bool _isRestoreStagingDir(String name) {
  const prefix = '.restore-staging-';
  if (!name.startsWith(prefix)) return false;
  return RegExp(r'^\d+$').hasMatch(name.substring(prefix.length));
}

/// §2.3/P3：zip 备份恢复（JSON + 文件一起恢复，恢复即完整）。
/// B2：按 plan v9 §四第 2 阶段第 5 条“备份恢复”五步执行（缺一步即协议未闭合）：
/// 1. 准备：zip 校验（路径、版本、容量峰值）通过后，先写恢复日志 PREPARING
///    （[RestoreJournalStore.writeInitial]，原子更新），再建 staging 目录解压；
///    正式文件与数据库在此之前一律不动；
/// 2. 完整性验证：staging 里每个文件条目落盘后核对存在与字节数；
/// 3. 一致快照：进维护状态（[AppDatabase._restoreMaintenance]，[db] getter
///    拒绝业务取连接）→ 切 WAL（未恢复过的库默认 journal_mode=delete，
///    该模式下 wal_checkpoint 是空操作，busy 恒为 0，故必须先切 WAL；
///    切不过说明另有连接占用，直接拒绝。一次恢复后库永久为 WAL，
///    见文件头 FR-26；再次恢复时切 WAL 是空操作）→ `PRAGMA wal_checkpoint(TRUNCATE)`
///    读第一列判定 busy（1 = 被活动读事务阻碍），busy 时重试等一会儿，
///    仍 busy 则拒绝、不复制主库文件 → 复制主库 + -wal/-shm 为快照并校验
///    （SQLite 文件头）；快照完成才写日志 SNAPSHOT_READY；
/// 4. 切换：先写切换清单（manifest：每条待装文件的相对路径 + 是否有原文件，
///    在 rollback 目录里），再写日志 FILES_SWITCHING，再逐文件进位——
///    原文件先移进 rollback 目录（`imports-rollback/<id>/`，与正式目录
///    同一文件系统，见 B-NEW-07 硬性约束），staging 文件再移进正式位置；
///    两次移动的目标都不存在，不用 File.rename 覆盖已存在目标、不触发
///    Win11 errno 5；进位段持 FileLifecycleGuard 锁（D-185），防并发
///    物理删除/孤儿清理/备份导出读到半截状态；未被备份引用的原文件不动
///    （B2-5c 已钉死：恢复不删旧文件，孤儿扫描接住它们——故不用 plan 字面
///    的整目录重命名，逐文件进位 + rollback 目录同样保证“被覆盖的原文件
///    内容必须能回来”）；
///    进位后核对正式文件存在与字节数，再写日志 DATABASE_RESTORING；
/// 5. 写库 + 提交：[AppDatabase.importBackupJsonInto] 事务整体覆盖数据库；
///    成功后写日志 COMMITTED，再清理 rollback 目录、快照、staging 与日志
///    （日志最后删：清理中途崩溃，下次启动见 COMMITTED 只清残留、不回滚）。
/// 任一步失败 → 补偿回滚（manifest 按磁盘实际状态把文件恢复原样；
/// 数据库由导入事务保护，进程内不换库文件——连接还开着，换文件不安全；
/// 快照只供崩溃后启动钩子用）并清理 staging / rollback / 快照 / 日志；
/// DB 已提交后才失败的，不再动文件（新库新文件已一致），保留日志 +
/// 快照 + rollback 目录，下次启动由启动钩子完整回滚。
/// 故障保证范围（B-NEW-16）：只覆盖进程强制终止，不承诺断电恢复。
/// 老 JSON 备份（`.qm2backup` 但内容是 JSON）不走这里，走
/// [AppDatabase.importBackupJsonInto]（见设置页的魔数识别）。
/// 十四批 M2：返回恢复警告列表（缺失/不可读的图块已从 JSON 引用里去掉、
/// 不展示，不阻断整库恢复）。`Future<void>` 改为 `Future<List<String>>`，
/// 只 await 的调用方源码兼容。
Future<List<String>> importBackupZipIntoImpl(
  QuizDatabase db,
  List<int> bytes, {
  String? dataDir,
}) async {
  final dir = dataDir ?? AppDatabase.dataDirectoryPath();
  // B 包 P1-04：zip 文件/解压总量上限 200MB 在解压前预判；不再用
  // 原来的 2GB 恢复上限（2GB 内存峰值在 Android 不现实）。预览入口
  // readBackupJsonFromZipImpl 同样用 maxBackupFileBytes。
  final entries = _readZipOrThrow(bytes, maxTotalBytes: maxBackupFileBytes);
  ZipEntryData? jsonEntry;
  for (final e in entries) {
    if (e.name == 'backup.json') jsonEntry = e;
  }
  if (jsonEntry == null) {
    throw BackupRestoreException('这份备份里没有题目数据（缺少 backup.json）');
  }
  final data = _decodeBackupJson(jsonEntry.bytes);
  for (final e in entries) {
    if (e.name == 'backup.json') continue;
    if (!e.name.startsWith('imports/') && !e.name.startsWith('slices/')) {
      throw BackupRestoreException('这份备份里有不支持的文件：${e.name}');
    }
  }
  // SR-P2-5：恢复前估算——峰值口径（SR2-19）：恢复中 staging 里的
  // 副本与原文件共存，峰值占用是 `现有占用 + 解压后总字节`，不是
  // 恢复后占用（`现有 − 将被覆盖的文件 + 解压后总字节`）。旧估算
  // 用恢复后口径：现有 1.5GB、备份带 0.9GB 文件、其中 0.5GB 会
  // 覆盖旧文件时估算 1.9GB 放行，峰值却是 2.4GB，盘空间不足时
  // staging 写一半失败。改后按峰值与 2GB 上限比较；将被覆盖的
  // 文件不再抵扣估算（它在恢复完成前一直占着磁盘）。
  // FR-42：峰值还要加上数据库快照大小（恢复第 3 步把整个库文件拷成
  // 快照，与原库共存；见 [_restoreSnapshotBytes]）。
  final fileEntries = [
    for (final e in entries)
      if (e.name != 'backup.json') e,
  ];
  final incomingBytes = fileEntries.fold<int>(
    0,
    (sum, e) => sum + e.bytes.length,
  );
  final usedBytes = await _dataDirFileUsageBytes(dir);
  final snapshotBytes = _restoreSnapshotBytes(dir);
  final peakBytes = usedBytes + incomingBytes + snapshotBytes;
  if (peakBytes > _maxRestoreBytes) {
    throw BackupRestoreException(
      '这份备份恢复时峰值占用会超过 2GB 存储上限（现有 ${_formatBytes(usedBytes)}，'
      '数据库快照 ${_formatBytes(snapshotBytes)}，'
      '恢复中峰值约 ${_formatBytes(peakBytes)}），请先清理无用文件或删掉'
      '不需要的题目再恢复',
    );
  }
  // 本次恢复的任务 id 与三处位置（日志 / staging / rollback / 快照
  // 全在数据目录内，同文件系统）。
  final taskId = _nextRestoreTaskId();
  final stagingDir = Directory(p.join(dir, 'restore-staging', taskId));
  final rollbackDir = Directory(p.join(dir, 'imports-rollback', taskId));
  final snapshotFile = File(p.join(dir, '.restore-snapshot-$taskId.db'));
  final dbFile = File(p.join(dir, 'quiz-master2.db'));
  final hadDbFile = dbFile.existsSync();
  final store = RestoreJournalStore(dataDir: Directory(dir));

  // 未完成的上次恢复：本次不许直接开始（启动钩子才是它的处理口径；
  // 进程内没有关连接的安全回滚条件）。COMMITTED 残留（上次恢复已完成、
  // 只剩收尾没清）例外：清掉残留材料后继续。
  if (store.formalFile.existsSync() ||
      store.backupFile.existsSync() ||
      store.tmpFile.existsSync()) {
    RestoreJournal? pending;
    if (store.formalFile.existsSync()) {
      try {
        pending = await store.validateFile(store.formalFile);
      } on JournalCorruptException catch (e) {
        throw BackupRestoreException('恢复日志损坏，请重启应用完成恢复后再试：${e.message}');
      }
    }
    if (pending != null && pending.stage == RestoreStage.committed) {
      await _cleanupRestoreMaterials(dir: dir, journal: pending, store: store);
    } else {
      throw BackupRestoreException('上次备份恢复未完成，请重启应用完成恢复后再试');
    }
  }

  AppDatabase._restoreMaintenance = true;
  RestoreJournal? journal;
  var dbCommitted = false;
  // 十四批 M2：恢复警告（图块引用校验产出；恢复失败时不返回，直接抛错）。
  var restoreWarnings = <String>[];
  try {
    // 第 1 步（准备）：日志先于一切文件改动落盘。PREPARING 写完之前，
    // 正式文件与数据库一律不动；staging 目录此时还没建。
    journal = RestoreJournal(
      taskId: taskId,
      rollbackDir: rollbackDir.path,
      stagingDir: stagingDir.path,
      snapshotPath: snapshotFile.path,
      stage: RestoreStage.preparing,
      status: RestoreStatus.inProgress,
    );
    try {
      await store.writeInitial(journal);
    } on JournalCorruptException catch (e) {
      throw BackupRestoreException('恢复日志写不进去，恢复已停止，原题库没动：${e.message}');
    } on JournalUpdateException catch (e) {
      throw BackupRestoreException('恢复日志写不进去，恢复已停止，原题库没动：${e.message}');
    }
    // 上次崩溃残留的旧式 staging（本次不是它）顺带清掉。
    // SR-P2-6：只清严格匹配 `.restore-staging-<纯数字时间戳>`
    // 的目录（见 [_isRestoreStagingDir]），同名用户目录不动。
    // 十四批 M2（P2-2）：经统一文件操作锁。
    try {
      for (final e in Directory(dir).listSync()) {
        if (e is Directory && _isRestoreStagingDir(p.basename(e.path))) {
          await FileLifecycleGuard.instance.deleteDirectory(e);
        }
      }
    } catch (_) {}
    await stagingDir.create(recursive: true);
    for (final e in fileEntries) {
      final dest = File(p.join(stagingDir.path, e.name));
      await dest.parent.create(recursive: true);
      await dest.writeAsBytes(e.bytes);
    }
    // 第 2 步（完整性验证）：staging 里每个文件条目都已落盘且字节数对得上。
    for (final e in fileEntries) {
      final staged = File(p.join(stagingDir.path, e.name));
      if (!staged.existsSync() || staged.lengthSync() != e.bytes.length) {
        throw BackupRestoreException('这份备份文件已损坏：${e.name} 解压后不完整');
      }
    }
    // 第 3 步（一致快照）：内存库（数据目录下没有库文件）无文件可快照，
    // 数据库由导入事务保护，跳过本步；文件库必须先拿到一致快照。
    if (hadDbFile) {
      await _takeRestoreSnapshot(db, dir, snapshotFile);
    }
    journal = await _advanceRestoreJournal(
      store,
      journal,
      RestoreStage.snapshotReady,
    );
    // 第 4 步（切换）准备：先写切换清单（manifest），再推进日志。
    // 清单记每条待装文件的相对路径 + 切换前正式位置是否有原文件；
    // 启动回滚只凭清单 + 磁盘实际状态分派，不猜测。
    final manifest = await _writeRestoreManifest(rollbackDir, fileEntries, dir);
    journal = await _advanceRestoreJournal(
      store,
      journal,
      RestoreStage.filesSwitching,
    );
    // D-185：逐文件进位持锁（FileLifecycleGuard.withLock）——进位期间
    // 物理删除/孤儿清理/备份导出读文件不得并发进场，避免在原文件已
    // 移进 rollback、staging 文件未到正式位置的间隙读到半截状态。
    // 只包进位这一段（毫秒级），不包整个恢复流程；调用链此前未持锁
    // （第 1 步的 stale-staging 清理已释锁），无重入风险。
    await FileLifecycleGuard.instance.withLock(() async {
      for (final item in manifest) {
        final rel = item['rel'] as String;
        final hadOriginal = item['hadOriginal'] == true;
        final staged = File(p.join(stagingDir.path, rel));
        final destPath = _resolveInsideDir(dir, rel);
        if (destPath == null) {
          throw BackupRestoreException('这份备份里有非法路径：$rel');
        }
        final dest = File(destPath);
        await dest.parent.create(recursive: true);
        if (hadOriginal && dest.existsSync()) {
          // 原文件先移进 rollback 目录（目标不存在，rename 不覆盖）。
          final backup = File(p.join(rollbackDir.path, rel));
          await backup.parent.create(recursive: true);
          await dest.rename(backup.path);
        }
        // staging 文件移进正式位置（目标不存在，rename 不覆盖）。
        await staged.rename(dest.path);
      }
    });
    // 进位后核对：每个条目都在正式位置且字节数对得上，再进写库阶段。
    for (final e in fileEntries) {
      final destPath = _resolveInsideDir(dir, e.name);
      final dest = destPath == null ? null : File(destPath);
      if (dest == null ||
          !dest.existsSync() ||
          dest.lengthSync() != e.bytes.length) {
        throw BackupRestoreException('恢复失败：${e.name} 没能装进正式位置，原题库没动');
      }
    }
    // 第 5 步（写库）：事务整体覆盖数据库（失败则事务回滚，库不动）。
    journal = await _advanceRestoreJournal(
      store,
      journal,
      RestoreStage.databaseRestoring,
    );
    await AppDatabase.importBackupJsonInto(db, data);
    dbCommitted = true;
    // 十四批 M2（P1-6）：先还原图块文件（第 4 步已进位），再校验 JSON
    // 引用——缺失/不可读的图块不展示：从 ocr_figures 里去掉、记一条
    // 恢复警告，不阻断整库恢复，不写无效引用。版本号原样保留（恢复不
    // 是内容编辑，content_version / answer_version 不动）。
    // 校验本身尽力而为：校验失败只记警告，不让恢复失败。
    try {
      restoreWarnings = await _pruneInvalidFigureRefs(db, dir);
    } catch (_) {
      restoreWarnings = ['图块引用校验失败，部分配图可能无法显示'];
    }
    // 提交：先写 COMMITTED，再清理。COMMITTED 写失败时直接删日志
    // （DB 与文件已是新的且一致，删日志等于“已完成”；删不掉才报失败，
    // 下次启动按 DATABASE_RESTORING 回滚到旧状态，与失败口径一致）。
    try {
      journal = await _advanceRestoreJournal(
        store,
        journal,
        RestoreStage.committed,
        status: RestoreStatus.completed,
      );
    } on BackupRestoreException {
      await _deleteJournalFiles(store);
      if (store.formalFile.existsSync() ||
          store.backupFile.existsSync() ||
          store.tmpFile.existsSync()) {
        throw BackupRestoreException('恢复已写入新数据，但收尾记录失败，下次启动将自动回滚到恢复前状态，原题库没动');
      }
      journal = null;
    }
  } catch (e) {
    if (journal != null && !dbCommitted) {
      // 进程内补偿：文件按 manifest 回滚（数据库由导入事务保护，
      // 连接还开着，不动库文件）；回滚失败则保留日志 + rollback +
      // 快照，下次启动重试回滚（此时不删日志）。
      var fileRollbackOk = true;
      try {
        await _rollbackRestoreFiles(dir: dir, rollbackDir: rollbackDir);
      } catch (_) {
        fileRollbackOk = false;
      }
      await _deleteDirQuietly(stagingDir);
      if (!fileRollbackOk) {
        // FR-29：文件回滚没完成时原“原题库没动”文案失实（文件可能半切换，
        // 须重启走启动钩子完成回滚）——改抛另一条文案，与本函数开头的
        // pending 日志文案（“上次备份恢复未完成，请重启应用完成恢复后再试”）
        // 同口径；原错误不再原样上抛。
        throw BackupRestoreException('恢复失败，文件回滚未完成，请重启应用完成回滚后再试');
      }
      // FR-28：补偿后复核库行引用文件存在性（plan v9 §四第 5 条）——
      // 只在切换已开始时核（journal.stage ≥ FILES_SWITCHING；切换前失败
      // 时文件根本没动过，核它只会用恢复前的旧悬空引用掩盖真正的失败原因）。
      // 不通过则保留日志与材料、报“回滚后复核未通过”，而不是删掉材料后
      // 按原错误上抛（悬空引用会在此后才被发现）。
      if (journal.stage.index >= RestoreStage.filesSwitching.index) {
        final missing = await _missingReferencedFiles(db, dir);
        if (missing.isNotEmpty) {
          throw BackupRestoreException(
            '恢复失败，文件回滚后复核未通过（${missing.length} 个被引用的'
            '文件不存在，如 ${missing.first}），请重启应用完成回滚后再试',
          );
        }
      }
      await _deleteDirQuietly(rollbackDir);
      await _deleteRestoreSnapshotFiles(snapshotFile);
      await _deleteJournalFiles(store);
      await _deleteEmptyRestoreParents(dir);
    } else if (journal != null && dbCommitted) {
      // DB 已提交新数据，进程内无法在不断连接的情况下换回快照；
      // 只删 staging，保留日志 + 快照 + rollback 目录，
      // 下次启动由启动钩子完整回滚（文件 + 数据库）。
      await _deleteDirQuietly(stagingDir);
    } else {
      await _deleteDirQuietly(stagingDir);
    }
    // SR-P2-6：区分错误来源，不再一律说“文件写不进去”——
    // 校验/数据问题（BackupRestoreException）原样抛；
    // 数据库错误是备份数据有问题（不是磁盘问题）；
    // 其余（IO 等）才是文件写不进去。
    // （数据库错误到这里时已被 [importBackupJsonIntoImpl] 包成
    // BackupRestoreException，故第二档只作防御：Drift 原生错误。）
    if (e is BackupRestoreException) rethrow;
    if (e is DriftWrappedException) {
      throw BackupRestoreException('恢复失败：备份数据有问题，原题库没动');
    }
    throw BackupRestoreException('恢复失败：文件写不进去，原题库没动');
  } finally {
    AppDatabase._restoreMaintenance = false;
  }
  // 成功收尾（COMMITTED 已写；只做清理，失败也尽力而为）：
  // rollback 目录、快照、staging 先清，日志最后删——清理中途崩溃，
  // 下次启动见 COMMITTED 只清残留、不回滚；父目录空了顺手删掉。
  await _deleteDirQuietly(rollbackDir);
  await _deleteRestoreSnapshotFiles(snapshotFile);
  await _deleteDirQuietly(stagingDir);
  await _deleteJournalFiles(store);
  await _deleteEmptyRestoreParents(dir);
  return restoreWarnings;
}

/// 十四批 M2（P1-6）：恢复后校验每题 ocr_figures 里的 crop_path——
/// 文件缺失或不可解码的图块从 JSON 里去掉（该图块不展示），每题记一条
/// 恢复警告。版本号不动（恢复原样保留）。非法 JSON 的行按原样保留
/// （渲染层按无图块处理，不在这里猜修）。
Future<List<String>> _pruneInvalidFigureRefs(
  QuizDatabase db,
  String dir,
) async {
  final warnings = <String>[];
  final rows = await db.select(db.questions).get();
  for (final row in rows) {
    if (row.ocrFigures.isEmpty) continue;
    List<dynamic> decoded;
    try {
      final parsed = jsonDecode(row.ocrFigures);
      if (parsed is! List) continue;
      decoded = parsed;
    } catch (_) {
      continue;
    }
    var badCount = 0;
    final kept = <Map<String, dynamic>>[];
    for (final item in decoded) {
      if (item is! Map<String, dynamic>) continue;
      final crop = item['crop_path'];
      if (crop is! String || crop.isEmpty) {
        kept.add(item);
        continue;
      }
      var ok = false;
      final abs = _resolveInsideDir(dir, crop);
      if (abs != null) {
        final f = File(abs);
        if (f.existsSync()) {
          try {
            ok = _decodableFigureBytes(await f.readAsBytes());
          } catch (_) {
            ok = false;
          }
        }
      }
      if (ok) {
        kept.add(item);
      } else {
        badCount++;
      }
    }
    if (badCount > 0) {
      await (db.update(
        db.questions,
      )..where((t) => t.id.equals(row.id))).write(
        QuestionsCompanion(ocrFigures: Value(jsonEncode(kept))),
      );
      warnings.add(
        '题目「${row.title}」有 $badCount 张配图缺失或已损坏，已从备份恢复中移除',
      );
    }
  }
  return warnings;
}

// ---------------------------------------------------------------------------
// B2：备份恢复五步协议的支撑函数（启动钩子 + 快照 + 清单 + 回滚）。
//
// 恢复代码一律以磁盘实际状态为准，不凭错误码 / 状态推断文件位置
// （Win11 实测：错误码读到 0 但文件根本没动，见 B-NEW-17）。
// 回滚路径上不用 File.rename 覆盖已存在目标：原文件移回时正式位置
// 是新内容，先删后移；新文件直接删。数据库快照拷回是唯一的例外——
// 目标已存在，用 atomicReplaceFile（Win ReplaceFileW / Linux rename，
// 见 journal_ffi.dart），替换后实地核查长度与文件头。
// ---------------------------------------------------------------------------

int _restoreTaskSeq = 0;

/// 本次恢复的任务 id（毫秒戳 + 进程内序号，避免同毫秒两次恢复撞目录名）。
String _nextRestoreTaskId() {
  _restoreTaskSeq++;
  return 'r${DateTime.now().millisecondsSinceEpoch}-$_restoreTaskSeq';
}

/// FR-28：进程内补偿后“库行引用文件存在性”复核（plan v9 §四第 5 条）。
/// 只核对库行直接引用的文件（见 [_directlyReferencedRelativePaths]：
/// questions 的 source_path / page_image_path / slice_path +
/// ocr_figures 里的 crop_path（十四批 M2）+ collect_tasks 的 source_path +
/// 十三批 M2：ocr_jobs 的 crop_path）。
/// 与孤儿扫描口径 [_referencedRelativePaths] 的列相同，但不用它本身：
/// 它另有两类派生保护（任务的 page-normalized.png 与 pages/ 下页图，
/// “有行即保护”、文件本身未必存在），直接做存在性检查会把未渲染过的
/// 任务也判为缺失，让每次失败恢复都报复核未通过。
/// 十四批 M5 修复轮 2（B-FIX2-1）：行直接引用集合不再这里手写一份，
/// 改为复用 [_directlyReferencedRelativePaths]，与孤儿扫描、备份导出
/// 共用同一口径来源。返回缺失的相对路径（空即通过）。
Future<List<String>> _missingReferencedFiles(
  QuizDatabase db,
  String dir,
) async {
  final refs = await _directlyReferencedRelativePaths(db, dir);
  final missing = <String>[];
  for (final rel in refs) {
    final abs = _resolveInsideDir(dir, rel);
    if (abs == null || !File(abs).existsSync()) missing.add(rel);
  }
  missing.sort();
  return missing;
}

/// FR-27：恢复日志阶段转移白名单——只允许
/// PREPARING → SNAPSHOT_READY → FILES_SWITCHING → DATABASE_RESTORING →
/// COMMITTED 的单步前进；跳级与回退一律非法（调用方顺序保证之外的一道
/// 防线；非法推进会让启动恢复按不可能的阶段分派、跳过应有的回滚步骤）。
/// [_advanceRestoreJournal] 在每次推进前用它校验，非法时抛
/// [BackupRestoreException]；[RestoreJournalStore.updateStage] 层不加
/// （调用方唯一）。
bool isLegalRestoreStageTransition(RestoreStage from, RestoreStage to) =>
    to.index == from.index + 1;

/// 日志阶段推进（原子更新；失败包成 [BackupRestoreException]，
/// 让设置页走同一条可见错误通道展示，不要静默吞掉）。
Future<RestoreJournal> _advanceRestoreJournal(
  RestoreJournalStore store,
  RestoreJournal journal,
  RestoreStage stage, {
  RestoreStatus? status,
}) async {
  // FR-27：非法跳转（跳级/回退）直接拒绝，不写日志。
  if (!isLegalRestoreStageTransition(journal.stage, stage)) {
    throw BackupRestoreException(
      '恢复日志阶段推进非法：${journal.stage.name} → ${stage.name}，'
      '只允许单步前进（PREPARING → SNAPSHOT_READY → FILES_SWITCHING → '
      'DATABASE_RESTORING → COMMITTED），恢复已停止，原题库没动',
    );
  }
  final next = journal.copyWith(stage: stage, status: status ?? journal.status);
  try {
    return await store.updateStage(next);
  } on JournalCorruptException catch (e) {
    // 诊断用：报出失败瞬间的三处文件实际状态（B-NEW-17：以磁盘实际状态为准）。
    final tmpExists = store.tmpFile.existsSync();
    final formalExists = store.formalFile.existsSync();
    final backupExists = store.backupFile.existsSync();
    throw BackupRestoreException(
      '恢复日志损坏，恢复已停止，原题库没动：${e.message}'
      '（当时磁盘状态：临时日志存在=$tmpExists，正式日志存在=$formalExists，'
      '备份日志存在=$backupExists）',
    );
  } on JournalUpdateException catch (e) {
    throw BackupRestoreException('恢复日志写不进去，恢复已停止，原题库没动：${e.message}');
  }
}

/// 一致快照（维护状态下、连接空闲时执行）：
/// ① 切 WAL——未恢复过的库默认 journal_mode=delete，该模式下
///    wal_checkpoint 是空操作（busy 恒为 0，log 为 -1，见尖峰后实测），
///    快照互斥无从谈起；切不过（另有连接占用）即拒绝，不在无法确认
///    互斥时快照。切 WAL 是持久化 pragma，首恢复后库文件保持 WAL，
///    搬库代码已连 -wal/-shm 一起搬（见 db_storage.dart），无连锁问题。
///    （FR-26：一次恢复后库永久为 WAL，无代码切回 delete，见文件头。）
/// ② `PRAGMA wal_checkpoint(TRUNCATE)` 读第一列判定 busy（1 = 有活动
///    读事务阻碍），busy 时等 200ms 再试，最多 10 次，仍 busy 则拒绝、
///    不复制主库文件（plan 验收 ⑤：必须用真实阻碍 TRUNCATE 的活动读
///    事务，空闲连接不算）。
/// ③ 复制主库 + -wal/-shm 为快照，校验快照存在、非空、SQLite 文件头。
Future<void> _takeRestoreSnapshot(
  QuizDatabase db,
  String dir,
  File snapshotFile,
) async {
  final modeRows = await db.customSelect('PRAGMA journal_mode=WAL').get();
  final mode = modeRows.isEmpty ? '' : '${modeRows.first.data.values.first}';
  if (mode != 'wal') {
    throw BackupRestoreException('恢复被拒绝：数据库正被另一处使用，无法取得一致快照，请关闭其他页面后重试');
  }
  var busy = true;
  for (var attempt = 0; attempt < 10; attempt++) {
    final rows = await db.customSelect('PRAGMA wal_checkpoint(TRUNCATE)').get();
    final first = rows.isEmpty ? 1 : rows.first.data.values.first;
    busy = first is int ? first == 1 : first != 0;
    if (!busy) break;
    await Future.delayed(const Duration(milliseconds: 200));
  }
  if (busy) {
    throw BackupRestoreException('恢复被拒绝：数据库正被另一处使用（检查点被占用），请稍后再试');
  }
  final dbPath = p.join(dir, 'quiz-master2.db');
  await File(dbPath).copy(snapshotFile.path);
  for (final suffix in ['-wal', '-shm']) {
    final side = File('$dbPath$suffix');
    if (side.existsSync()) {
      await side.copy('${snapshotFile.path}$suffix');
    }
  }
  if (!snapshotFile.existsSync() || snapshotFile.lengthSync() == 0) {
    throw BackupRestoreException('恢复失败：数据库快照没能写出来，原题库没动');
  }
  final header = await snapshotFile.openRead(0, 16).first;
  if (utf8.decode(header, allowMalformed: true) != 'SQLite format 3\u0000') {
    throw BackupRestoreException('恢复失败：数据库快照已损坏，原题库没动');
  }
}

/// 写切换清单（manifest.json，放在 rollback 目录里）：
/// 每条待装文件的相对路径 + 切换前正式位置是否有原文件。
/// 清单在 FILES_SWITCHING 日志推进前写完、flush 落盘；启动回滚
/// 只凭清单 + 磁盘实际状态分派。
Future<List<Map<String, Object?>>> _writeRestoreManifest(
  Directory rollbackDir,
  List<ZipEntryData> fileEntries,
  String dir,
) async {
  final files = <Map<String, Object?>>[];
  for (final e in fileEntries) {
    final destPath = _resolveInsideDir(dir, e.name);
    final hadOriginal = destPath != null && File(destPath).existsSync();
    files.add({'rel': e.name, 'hadOriginal': hadOriginal});
  }
  await rollbackDir.create(recursive: true);
  await File(p.join(rollbackDir.path, 'manifest.json'))
      .writeAsString(jsonEncode({'version': 1, 'files': files}), flush: true);
  return files;
}

/// 读切换清单；缺失或损坏返回 null（调用方退化为枚举 rollback 目录）。
Future<List<Map<String, Object?>>?> _readRestoreManifest(
  Directory rollbackDir,
) async {
  final file = File(p.join(rollbackDir.path, 'manifest.json'));
  if (!file.existsSync()) return null;
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map || decoded['version'] != 1) return null;
    final files = decoded['files'];
    if (files is! List) return null;
    return [
      for (final item in files)
        if (item is Map<String, dynamic>) Map<String, Object?>.from(item),
    ];
  } catch (_) {
    return null;
  }
}

/// 日志里记录的路径（本实现写绝对路径；相对路径视为数据目录内相对位置，
/// 越出数据目录的一律不认——清理/回滚不得删到数据目录外）。
String? _resolveJournalRecordedPath(String dir, String recorded) {
  final abs = p.isAbsolute(recorded)
      ? p.normalize(recorded)
      : p.normalize(p.join(dir, recorded));
  final base = p.normalize(dir);
  if (abs != base && !abs.startsWith('$base${p.separator}')) return null;
  return abs;
}

/// 按磁盘实际状态把文件恢复到恢复前（启动钩子与进程内补偿共用）。
/// 对清单里的每一项：
/// - 有原文件、且原文件在 rollback 目录里 → 正式位置是新内容，
///   先删后移，把原文件移回；
/// - 有原文件、但 rollback 里没有 → 切换还没动它，正式文件就是原文件，不动；
/// - 无原文件（新增）→ 正式位置若已装进来，删掉。
/// 清单缺失/损坏时退化为枚举 rollback 目录、把其中文件移回正式位置
/// （新增文件无法识别，留给孤儿扫描——协议 §6 允许的残留类）。
Future<void> _rollbackRestoreFiles({
  required String dir,
  required Directory rollbackDir,
}) async {
  if (!rollbackDir.existsSync()) return;
  final manifest = await _readRestoreManifest(rollbackDir);
  Future<void> restoreOne(String rel) async {
    final formalPath = _resolveInsideDir(dir, rel);
    if (formalPath == null) return;
    final backupFile = File(p.join(rollbackDir.path, rel));
    if (!backupFile.existsSync()) return;
    await _deletePathQuietly(formalPath);
    await File(formalPath).parent.create(recursive: true);
    await backupFile.rename(formalPath);
  }

  if (manifest != null) {
    for (final item in manifest) {
      final rel = item['rel'];
      if (rel is! String) continue;
      final hadOriginal = item['hadOriginal'] == true;
      final backupFile = File(p.join(rollbackDir.path, rel));
      if (hadOriginal) {
        if (backupFile.existsSync()) {
          await restoreOne(rel);
        }
        // rollback 里没有原文件 → 切换还没动它，正式文件就是原文件，不动。
      } else {
        // 新增文件：若已装进来，删掉。
        final formalPath = _resolveInsideDir(dir, rel);
        if (formalPath != null) await _deletePathQuietly(formalPath);
      }
    }
    // 防御：rollback 目录里清单之外的残留文件也移回正式位置。
    await for (final e in rollbackDir.list(recursive: true)) {
      if (e is! File) continue;
      final relPath = p
          .relative(e.path, from: rollbackDir.path)
          .replaceAll('\\', '/');
      if (relPath == 'manifest.json') continue;
      if (manifest.any((m) => m['rel'] == relPath)) continue;
      await restoreOne(relPath);
    }
  } else {
    await for (final e in rollbackDir.list(recursive: true)) {
      if (e is! File) continue;
      final relPath = p
          .relative(e.path, from: rollbackDir.path)
          .replaceAll('\\', '/');
      if (relPath == 'manifest.json') continue;
      await restoreOne(relPath);
    }
  }
}

/// 用快照恢复数据库文件（只供启动钩子：连接未建，换文件安全）。
/// 顺序：删当前 -wal/-shm → 快照拷到同目录临时文件 → atomicReplaceFile
/// 换进正式位置（目标已存在才用它；目标不存在直接拷）→ 拷回快照的
/// -wal/-shm → 核查正式文件长度与文件头。替换后不只看返回码，
/// 实地核查文件确实是快照内容（Win11 实测：错误码为 0 但文件没动）。
Future<void> _restoreDbFromSnapshot({
  required String dbPath,
  required File snapshotFile,
}) async {
  if (!snapshotFile.existsSync() || snapshotFile.lengthSync() == 0) {
    throw JournalCorruptException(
      '恢复快照缺失或为空，无法把数据库恢复到恢复前状态，已停止启动以保护现有数据；'
      '请手动处理后再启动（核对数据目录下的 restore-journal.json、'
      'imports-rollback 目录与数据库快照文件，不要删除这些文件）',
    );
  }
  final header = await snapshotFile.openRead(0, 16).first;
  if (utf8.decode(header, allowMalformed: true) != 'SQLite format 3\u0000') {
    throw JournalCorruptException(
      '恢复快照已损坏，无法把数据库恢复到恢复前状态，已停止启动以保护现有数据；'
      '请手动处理后再启动（核对数据目录下的 restore-journal.json、'
      'imports-rollback 目录与数据库快照文件，不要删除这些文件）',
    );
  }
  final dbFile = File(dbPath);
  for (final suffix in ['-wal', '-shm']) {
    await _deletePathQuietly('$dbPath$suffix');
  }
  if (dbFile.existsSync()) {
    // 快照先拷到同目录临时文件再原子替换，快照原件保留——
    // 回滚中途再崩，重启还能用同一快照重试（幂等）。
    final tmp = File('$dbPath.restore-tmp');
    try {
      await snapshotFile.copy(tmp.path);
      final code = await atomicReplaceFile(
        target: dbPath,
        replacement: tmp.path,
        backup: '$dbPath.bak',
      );
      final ok =
          dbFile.existsSync() &&
          dbFile.lengthSync() == snapshotFile.lengthSync();
      if (!ok) {
        throw JournalCorruptException(
          '恢复快照写回数据库失败（原子替换返回码 $code，但正式库文件与快照不一致），'
          '已停止启动以保护现有数据；请手动处理后再启动',
        );
      }
    } finally {
      await _deletePathQuietly(tmp.path);
      await _deletePathQuietly('$dbPath.bak');
    }
  } else {
    await snapshotFile.copy(dbPath);
  }
  for (final suffix in ['-wal', '-shm']) {
    final side = File('${snapshotFile.path}$suffix');
    if (side.existsSync()) {
      await side.copy('$dbPath$suffix');
    }
  }
  final doneHeader = await dbFile.openRead(0, 16).first;
  if (utf8.decode(doneHeader, allowMalformed: true) !=
      'SQLite format 3\u0000') {
    throw JournalCorruptException('恢复快照写回后数据库文件头不对，已停止启动以保护现有数据；请手动处理后再启动');
  }
}

/// 删快照文件及其 -wal/-shm（静默，失败不阻断）。
Future<void> _deleteRestoreSnapshotFiles(File snapshotFile) async {
  for (final suffix in ['', '-wal', '-shm']) {
    await _deletePathQuietly('${snapshotFile.path}$suffix');
  }
}

/// 恢复工作目录的父目录（restore-staging / imports-rollback）在子目录
/// 删完后若已空，顺手删掉（只删空目录：非空时 Directory.delete 抛错，
/// 静默跳过，不动别人的任务目录）。
/// 十四批 M2（P2-2）：经统一文件操作锁（仅删空目录）。
Future<void> _deleteEmptyRestoreParents(String dir) async {
  for (final name in ['restore-staging', 'imports-rollback']) {
    await FileLifecycleGuard.instance.deleteEmptyDirectory(
      Directory(p.join(dir, name)),
    );
  }
}

/// 删恢复日志三处文件（正式 / 备份 / 临时，静默，失败不阻断）。
Future<void> _deleteJournalFiles(RestoreJournalStore store) async {
  await _deletePathQuietly(store.formalFile.path);
  await _deletePathQuietly(store.backupFile.path);
  await _deletePathQuietly(store.tmpFile.path);
}

/// 清本次恢复的残留材料（rollback 目录、staging 目录、快照、日志；
/// 日志最后删）。只删数据目录内的记录路径，越界的不碰。
Future<void> _cleanupRestoreMaterials({
  required String dir,
  required RestoreJournal journal,
  required RestoreJournalStore store,
}) async {
  final rollback = _resolveJournalRecordedPath(dir, journal.rollbackDir);
  if (rollback != null) await _deleteDirQuietly(Directory(rollback));
  final staging = _resolveJournalRecordedPath(dir, journal.stagingDir);
  if (staging != null) await _deleteDirQuietly(Directory(staging));
  final snapshot = _resolveJournalRecordedPath(dir, journal.snapshotPath);
  if (snapshot != null) {
    await _deleteRestoreSnapshotFiles(File(snapshot));
  }
  await _deleteJournalFiles(store);
  await _deleteEmptyRestoreParents(dir);
}

/// B2：启动恢复——按日志阶段把中断的恢复回滚到恢复前状态。
/// - PREPARING：快照不存在、正式数据没动过，只清准备材料；
/// - SNAPSHOT_READY：切换没开始，正式文件与数据库都是原样，只清残留；
/// - FILES_SWITCHING / DATABASE_RESTORING：文件按清单回滚；
///   数据库用快照恢复（[restoreDb] 须为 true，即连接未建时）；
///   快照缺失时：FILES_SWITCHING 下数据库还没动过（写库在
///   DATABASE_RESTORING 才开始），只回滚文件；DATABASE_RESTORING
///   下数据库可能已是新状态，无快照无法回滚，拒绝启动；
/// - COMMITTED：不再回滚，只清残留。
/// 回滚完成后再清理残留材料；回滚本身失败时保留现场（不删日志），
/// 下次启动重试或人工处理。
Future<void> rollbackInterruptedRestore({
  required String dir,
  required String dbPath,
  required RestoreJournal journal,
  required RestoreJournalStore store,
  bool restoreDb = true,
}) async {
  if (journal.stage == RestoreStage.committed) {
    await _cleanupRestoreMaterials(dir: dir, journal: journal, store: store);
    return;
  }
  if (journal.stage.index >= RestoreStage.filesSwitching.index) {
    final rollbackPath = _resolveJournalRecordedPath(dir, journal.rollbackDir);
    final stagingPath = _resolveJournalRecordedPath(dir, journal.stagingDir);
    if (rollbackPath == null) {
      throw JournalCorruptException(
        '恢复日志里的回滚目录不在数据目录内，无法安全回滚，已停止启动以保护现有数据；请手动处理后再启动',
      );
    }
    final rollbackDir = Directory(rollbackPath);
    if (!rollbackDir.existsSync()) {
      // rollback 目录没了：进程内补偿删它在先（文件已恢复、staging 已清），
      // 还是外部删的，分不清——看 staging 是否还在：staging 也没了，
      // 按“补偿已做完、只剩日志没清”处理；staging 还在则拒绝。
      final stagingGone =
          stagingPath == null || !Directory(stagingPath).existsSync();
      if (!stagingGone) {
        throw JournalCorruptException(
          '回滚目录缺失，无法把文件恢复到恢复前状态，已停止启动以保护现有数据；'
          '请手动处理后再启动（核对数据目录下的 restore-journal.json、'
          'imports-rollback 目录与数据库快照文件，不要删除这些文件）',
        );
      }
    } else {
      await _rollbackRestoreFiles(dir: dir, rollbackDir: rollbackDir);
    }
    if (restoreDb) {
      final snapshotPath = _resolveJournalRecordedPath(
        dir,
        journal.snapshotPath,
      );
      final snapshotFile = snapshotPath == null ? null : File(snapshotPath);
      final snapshotExists = snapshotFile != null && snapshotFile.existsSync();
      if (snapshotExists) {
        await _restoreDbFromSnapshot(
          dbPath: dbPath,
          snapshotFile: snapshotFile,
        );
      } else if (journal.stage == RestoreStage.databaseRestoring &&
          File(dbPath).existsSync()) {
        throw JournalCorruptException(
          '恢复快照缺失，无法把数据库恢复到恢复前状态，已停止启动以保护现有数据；'
          '请手动处理后再启动（核对数据目录下的 restore-journal.json、'
          'imports-rollback 目录与数据库快照文件，不要删除这些文件）',
        );
      }
      // FILES_SWITCHING + 快照缺失：写库还没开始，库文件本身就是原样，不用恢复。
    }
  }
  await _cleanupRestoreMaterials(dir: dir, journal: journal, store: store);
}

/// B2：启动恢复钩子（database.dart 的 _openDb 在删老库之后、
/// QuizDatabase.file 之前调用）。[locateAndRecover] 按“正式 → 备份 →
/// 临时”顺序定位有效日志；日志损坏 → 抛 [JournalCorruptException]
/// （带给用户看得懂的“恢复日志损坏，请手动处理”文案），_openDb
/// 拒绝开库、不滑入 fallback、不静默继续。
Future<void> performStartupRestoreIfNeeded(String dbPath) async {
  final dir = p.dirname(dbPath);
  // 十四批 M2（P1-B）：崩溃残留的 `.backup-staging-<时间戳>` 在应用
  // 启动时按严格匹配规则清理（名字必须是 `.backup-staging-<纯数字
  // 时间戳>`，其他同名目录一概不动）。启动时不可能有进行中的导出，
  // 清理是安全的。
  await FileLifecycleGuard.instance.cleanupStaleBackupStagingDirs(dir);
  final store = RestoreJournalStore(dataDir: Directory(dir));
  late final RestoreJournal? journal;
  try {
    journal = await store.locateAndRecover();
  } on JournalCorruptException catch (e) {
    throw JournalCorruptException(
      '恢复日志损坏，已停止启动以保护现有数据：${e.message}。'
      '请手动处理后再启动（核对数据目录下的 restore-journal.json、'
      'imports-rollback 目录与数据库快照文件，不要删除这些文件）',
      path: e.path,
    );
  }
  if (journal == null) return;
  await rollbackInterruptedRestore(
    dir: dir,
    dbPath: dbPath,
    journal: journal,
    store: store,
  );
}

extension AppDatabaseBackup on AppDatabase {
  /// 备份：把题库导出为 JSON 文本（恢复时校验后整体覆盖）。
  Future<String> exportBackupJson() async =>
      AppDatabase.exportBackupJsonFrom(await db);

  /// B4.2：恢复：整体覆盖——先校验（版本 + 关键表 + 行类型），
  /// 校验通过才清表再插回；校验不过一律不动原库。
  /// 清表/插表只按 backupTables 一份清单走（§2.3：删掉另一份手写
  /// 清单）；question_boxes 先清、随 questions 之后插（外键是逻辑
  /// 上的，没有声明 FK，顺序只是为可读性）。
  /// 恢复后 settings.schemaVersion 写回当前版本。
  /// Stage 4：恢复成功后只发一个含全部六种 kind 的事件（方案 §四；
  /// D-94：恢复覆盖 recently_viewed_questions 表，历史也在内）。
  Future<void> importBackupJson(Map<String, dynamic> data) async {
    await AppDatabase.importBackupJsonInto(await db, data);
    DataChangeBus.instance.emit(
      const DataChangeEvent(
        kinds: {
          DataChangeKind.badges,
          DataChangeKind.reviewRecords,
          DataChangeKind.subjects,
          DataChangeKind.questions,
          DataChangeKind.settings,
          DataChangeKind.recentlyViewed,
        },
      ),
    );
  }

  /// zip 备份（实例版）。
  Future<List<int>> exportBackupZip() async =>
      AppDatabase.exportBackupZipFrom(await db);

  /// 十四批 M2：带警告的 zip 备份（实例版）——字节 + 可见警告列表
  /// （缺失/不可读图块的题目）。设置页走这条。
  /// WP-C #8 U3-2：另含 `brokenFiles`（未进包的文件清单）与 `status`
  ///（complete 仅当零警告且零 BROKEN 文件）。
  Future<
    ({
      List<int> bytes,
      List<String> warnings,
      List<String> brokenFiles,
      BackupExportStatus status,
    })
  >
  exportBackupZipWithReport() async =>
      AppDatabase.exportBackupZipFromWithReport(await db);

  /// zip 备份恢复（实例版，按已读到的字节恢复）。成功后只发一个含
  /// 全部六种 kind 的事件（方案 §四；D-94：同上，历史也在内）。
  /// GPT-P1：只接受字节，不再提供按文件路径重读的入口——校验过的
  /// 字节与导入的字节必须是同一份，消除校验与使用之间的 TOCTOU
  /// 窗口（旧 `importBackupZipFile` 已删除）。
  /// 十四批 M2：返回恢复警告列表（缺失/不可读的图块已从 JSON 引用里
  /// 去掉、不展示）。
  Future<List<String>> importBackupZip(List<int> bytes) async {
    final warnings = await AppDatabase.importBackupZipInto(await db, bytes);
    DataChangeBus.instance.emit(
      const DataChangeEvent(
        kinds: {
          DataChangeKind.badges,
          DataChangeKind.reviewRecords,
          DataChangeKind.subjects,
          DataChangeKind.questions,
          DataChangeKind.settings,
          DataChangeKind.recentlyViewed,
        },
      ),
    );
    return warnings;
  }
}
