// B4：database.dart 拆分——备份与恢复：JSON 导出/导入 / zip 备份/恢复 / 校验。
// 与 database.dart 同一库（part of），共享库私有成员；纯重构，行为不变。

part of 'database.dart';

/// B4.2：导出（可单测版）：直接对传入的库句柄导出，不碰单例。
/// §4.4：用 dart:convert 的 jsonEncode（手写 _jsonValue 只转义了
/// `\` / `"` / `\n`，漏 `\r` / `\t` / `\b` / `\f` 与其它控制字符，
/// 含制表符或回车的笔记会导出非法 JSON、恢复不了）。
/// §2.3：保持表名平铺在顶层，额外加 `_meta`
/// {schemaVersion, appVersion, exportedAt}（先加后用）。
Future<String> exportBackupJsonFromImpl(Database db) async {
  final out = <String, dynamic>{
    '_meta': {
      'schemaVersion': AppDatabase.schemaVersion,
      'appVersion': AppDatabase.appVersion,
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
    },
  };
  for (final t in AppDatabase.backupTables) {
    out[t] = await db.query(t);
  }
  return jsonEncode(out);
}

/// §2.3：恢复前校验（纯校验，不动库；设置页选文件时先调它给即时
/// 反馈，importBackupJsonInto 里再调一次，双保险）。
/// 校验顺序：① `_meta.schemaVersion` 存在且为整数（缺失 → 按 v1
/// 备份处理，拒绝：v1 从未发布、老库已删，不存在合法的 v1 备份）；
/// ② `== 2` 才放行，`> 2` 拒绝（备份来自更新的版本），`< 2` 也拒绝；
/// ③ 全部 13 张表键齐全且为数组；④ 每行是对象、主键非空、
/// 必填列齐全且类型正确；⑤ 文件路径合法（见 [_validateBackupRowPaths]）。
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
  if (sv != AppDatabase.schemaVersion) {
    throw BackupRestoreException('这份备份是旧版本（v$sv）的，新版不再支持恢复');
  }
  for (final t in AppDatabase.backupTables) {
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
  'settings': {'key': String, 'value': String},
};

/// 整数主键的表（自增或 CHECK(id = 1) 的单行表）。
const _integerIdBackupTables = {
  'cause_records',
  'review_history',
  'review_state',
  'recent_tasks',
};

void _validateBackupRow(String table, Map row) {
  final id = row['id'] ?? row['key'] ?? '?';
  // 主键非空：TEXT 主键必须是非空字符串；整数主键出现时
  // 必须是非空整数；cause_records / review_history 的自增 id
  // 缺失时允许（入库自动编号），review_state / recent_tasks
  // 的 id 由必填列检查覆盖（_requiredBackupColumns 里是 int）。
  // SR2-16：`''` 是合法 String，旧写法只查 `is! String` 会放过
  // 空串主键（SQLite 的 TEXT PRIMARY KEY 允许空串），恢复后库里
  // 出现 `id: ''` 的脏行；必填 String 列同理。
  if (table == 'settings') {
    if (row['key'] is! String || (row['key'] as String).isEmpty) {
      throw BackupRestoreException('这份备份文件已损坏：settings 表里有行缺少主键 key');
    }
  } else if (_integerIdBackupTables.contains(table)) {
    if (row.containsKey('id') && row['id'] is! int) {
      throw BackupRestoreException('这份备份文件已损坏：$table 表 $id 行的主键 id 为空或类型不对');
    }
  } else {
    if (row['id'] is! String || (row['id'] as String).isEmpty) {
      throw BackupRestoreException('这份备份文件已损坏：$table 表里有行缺少主键 id');
    }
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

/// B3-P01：校验备份里一行携带的文件路径（见
/// [AppDatabase.isAllowedDataRelativePath]）。只校验存文件路径的列：
/// questions 的 source_path / page_image_path / slice_path，
/// collect_tasks 的 source_path。空值（null / ''）表示没有
/// 文件，放行；非字符串或不合法路径 → 抛 [BackupRestoreException]
///（带表名、行 id、列名与原值，拒绝整个恢复）。
void _validateBackupRowPaths(String table, Map row) {
  const pathColumns = {
    'questions': ['source_path', 'page_image_path', 'slice_path'],
    'collect_tasks': ['source_path'],
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

/// B4.2：恢复（可单测版）。
/// SR-P2-4：插库时的残余异常统一包成 [BackupRestoreException]
/// （文案写“备份数据有问题”）：校验已拦住大多数非法行，但列名
/// 不在表里、值超约束等仍可能在插库时才抛原生 DatabaseException，
/// 旧写法会把 sqlite 原文直接展示给用户。
Future<void> importBackupJsonIntoImpl(
  Database db,
  Map<String, dynamic> data,
) async {
  AppDatabase.validateBackupData(data);
  final clearOrder = <String>[
    'question_boxes',
    ...AppDatabase.backupTables.reversed.where((t) => t != 'question_boxes'),
  ];
  try {
    await db.transaction((txn) async {
      for (final t in clearOrder) {
        await txn.delete(t);
      }
      for (final t in AppDatabase.backupTables) {
        final rows = data[t];
        if (rows is! List) continue;
        for (final row in rows) {
          if (row is! Map) continue;
          await txn.insert(
            t,
            Map<String, Object?>.from(row),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
      // §2.3：恢复后 settings.schemaVersion 写回 2（备份里的 settings
      // 行若缺这一键，在此补写；若有，也以 2 为准）。
      await txn.insert('settings', {
        'key': 'schemaVersion',
        'value': '${AppDatabase.schemaVersion}',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  } on BackupRestoreException {
    rethrow;
  } on DatabaseException catch (e) {
    // 事务已回滚，原库不动；只换文案，不吞错因。
    throw BackupRestoreException('这份备份数据有问题，恢复失败：$e');
  }
}

/// §2.3/P3：zip 文件级备份（`backup.json` + `imports/` + `slices/`）。
/// 只打包库里引用到的文件（questions 的 source_path /
/// page_image_path / slice_path + collect_tasks 的 source_path）；
/// 无引用的孤儿文件不进备份。缺文件（路径在库里、文件不在盘上）
/// 不进包，恢复后该题走“图片缺失”，不静默造假文件。
Future<List<int>> exportBackupZipFromImpl(
  Database db, {
  String? dataDir,
}) async {
  final dir = dataDir ?? AppDatabase.dataDirectoryPath();
  final json = await AppDatabase.exportBackupJsonFrom(db);
  final entries = <ZipEntryData>[
    ZipEntryData('backup.json', utf8.encode(json)),
  ];
  final refs = await _referencedRelativePaths(db, dir);
  final sorted = refs.toList()..sort();
  for (final rel in sorted) {
    if (!rel.startsWith('imports/') && !rel.startsWith('slices/')) {
      continue;
    }
    final abs = _resolveInsideDir(dir, rel);
    if (abs == null) continue;
    final f = File(abs);
    if (!f.existsSync()) continue;
    entries.add(ZipEntryData(rel, await f.readAsBytes()));
  }
  return buildZip(entries);
}

List<ZipEntryData> _readZipOrThrow(List<int> bytes) {
  try {
    return readZip(bytes);
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
  final entries = _readZipOrThrow(bytes);
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
/// 1. 解包并校验每个条目路径（zip slip：任一条目非法 → 拒绝整个包，
///    见 zip_archive.dart；含 `imports/` / `slices/` 之外的文件
///    条目也拒绝）；
/// 2. SR-P2-5：文件进位前按峰值占用估算（现有占用 + 解压后总字节，
///    SR2-19：staging 副本与原文件共存，峰值不是恢复后占用），
///    超 2GB 拒绝整个恢复；
/// 3. 先把文件解到 staging 目录（数据目录内的
///    `.restore-staging-<时间戳>`），再校验 backup.json；
/// 4. 校验通过后：文件原子替换进位（先把被覆盖的原文件挪到
///    staging 的 `.overwritten/` 里），再走 [AppDatabase.importBackupJsonInto]
///    整体覆盖数据库；
/// 5. 任一步失败 → 删 staging、不动原库（数据库失败时已移入的
///    文件也从 `.overwritten/` 移回）；成功后删 staging。
/// 老 JSON 备份（`.qm2backup` 但内容是 JSON）不走这里，走
/// [AppDatabase.importBackupJsonInto]（见设置页的魔数识别）。
Future<void> importBackupZipIntoImpl(
  Database db,
  List<int> bytes, {
  String? dataDir,
}) async {
  final dir = dataDir ?? AppDatabase.dataDirectoryPath();
  final entries = _readZipOrThrow(bytes);
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
  final fileEntries = [
    for (final e in entries)
      if (e.name != 'backup.json') e,
  ];
  final incomingBytes = fileEntries.fold<int>(
    0,
    (sum, e) => sum + e.bytes.length,
  );
  final usedBytes = await _dataDirFileUsageBytes(dir);
  final peakBytes = usedBytes + incomingBytes;
  if (peakBytes > _maxRestoreBytes) {
    throw BackupRestoreException(
      '这份备份恢复时峰值占用会超过 2GB 存储上限（现有 ${_formatBytes(usedBytes)}，'
      '恢复中峰值约 ${_formatBytes(peakBytes)}），请先清理孤儿文件或删掉'
      '不需要的题目再恢复',
    );
  }
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final staging = Directory(p.join(dir, '.restore-staging-$stamp'));
  final overwritten = Directory(p.join(staging.path, '.overwritten'));
  final movedIn = <String>[];
  final backedUp = <({String current, String backup})>[];
  try {
    // 上次崩溃残留的 staging（本次不是它）顺带清掉。
    // SR-P2-6：只清严格匹配 `.restore-staging-<纯数字时间戳>`
    // 的目录（见 [_isRestoreStagingDir]），同名用户目录不动。
    try {
      for (final e in Directory(dir).listSync()) {
        if (e is Directory && _isRestoreStagingDir(p.basename(e.path))) {
          await e.delete(recursive: true);
        }
      }
    } catch (_) {}
    await staging.create(recursive: true);
    await overwritten.create(recursive: true);
    for (final e in entries) {
      if (e.name == 'backup.json') continue;
      final dest = File(p.join(staging.path, e.name));
      await dest.parent.create(recursive: true);
      await dest.writeAsBytes(e.bytes);
    }
    // 文件进位：原文件先挪到 .overwritten/，失败可移回。
    for (final e in entries) {
      if (e.name == 'backup.json') continue;
      final staged = File(p.join(staging.path, e.name));
      final destPath = _resolveInsideDir(dir, e.name);
      if (destPath == null) {
        throw BackupRestoreException('这份备份里有非法路径：${e.name}');
      }
      final dest = File(destPath);
      await dest.parent.create(recursive: true);
      if (dest.existsSync()) {
        final backup = File(p.join(overwritten.path, e.name));
        await backup.parent.create(recursive: true);
        await dest.rename(backup.path);
        backedUp.add((current: dest.path, backup: backup.path));
      }
      await staged.rename(dest.path);
      movedIn.add(dest.path);
    }
    // 数据库整体覆盖（事务内；失败抛错走下面的回滚）。
    await AppDatabase.importBackupJsonInto(db, data);
  } catch (e) {
    for (final m in movedIn) {
      await _deletePathQuietly(m);
    }
    for (final b in backedUp.reversed) {
      try {
        if (File(b.backup).existsSync()) {
          await File(b.backup).rename(b.current);
        }
      } catch (_) {}
    }
    await _deleteDirQuietly(staging);
    // SR-P2-6：区分错误来源，不再一律说“文件写不进去”——
    // 校验/数据问题（BackupRestoreException）原样抛；
    // 数据库错误是备份数据有问题（不是磁盘问题）；
    // 其余（IO 等）才是文件写不进去。
    if (e is BackupRestoreException) rethrow;
    if (e is DatabaseException) {
      throw BackupRestoreException('恢复失败：备份数据有问题，原题库没动');
    }
    throw BackupRestoreException('恢复失败：文件写不进去，原题库没动');
  }
  await _deleteDirQuietly(staging);
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
  /// 恢复后 settings.schemaVersion 写回 2。
  /// Stage 4：恢复成功后只发一个含全部五种 kind 的事件（方案 §四）。
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
        },
      ),
    );
  }

  /// zip 备份（实例版）。
  Future<List<int>> exportBackupZip() async =>
      AppDatabase.exportBackupZipFrom(await db);

  /// zip 备份恢复（实例版）。成功后只发一个含全部五种 kind 的事件
  ///（方案 §四）；按路径恢复的 [importBackupZipFile] 调本方法，
  /// 不另发事件。
  Future<void> importBackupZip(List<int> bytes) async {
    await AppDatabase.importBackupZipInto(await db, bytes);
    DataChangeBus.instance.emit(
      const DataChangeEvent(
        kinds: {
          DataChangeKind.badges,
          DataChangeKind.reviewRecords,
          DataChangeKind.subjects,
          DataChangeKind.questions,
          DataChangeKind.settings,
        },
      ),
    );
  }

  /// zip 备份恢复（实例版，按文件路径读）。
  Future<void> importBackupZipFile(String path) async {
    final bytes = await File(path).readAsBytes();
    await importBackupZip(bytes);
  }
}
