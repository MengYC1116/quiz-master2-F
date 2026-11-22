// B4：database.dart 拆分——路径解析与数据目录：dataDirectoryPath / resolveDataPath / isAllowedDataRelativePath / newBoxId / databaseExistsAt / test 目录重定向。
// 与 database.dart 同一库（part of），共享库私有成员；纯重构，行为不变。

part of 'database.dart';

String dataDirectoryPathImpl() {
  final override = AppDatabase.testDataDirectory;
  if (override != null) return override;
  final def = _defaultDataDirectoryPath();
  try {
    final marker = File(p.join(def, 'db_location.txt'));
    if (marker.existsSync()) {
      final custom = marker.readAsStringSync().trim();
      if (custom.isNotEmpty) return custom;
    }
  } catch (_) {}
  return def;
}

/// §1.4/§4.6：库内相对路径 → 绝对路径（统一 resolver）。
/// - 相对路径（如 `imports/<task-id>/original.jpg`）：经
///   [AppDatabase._resolveInsideDir] 拼上数据目录，`..` 越出数据目录返回 null
///  （按“文件缺失”处理，见 §4.6）；
/// - 绝对路径：默认拒绝（返回 null）。库里只存相对路径，生产
///   代码没有任何理由传绝对路径；旧的“原样放行”会让一条被
///   篡改的库内绝对路径直达任意文件。测试里确实需要解析绝对
///   路径时，调用方显式传 `allowAbsolute: true`（例外通道，
///   只能出现在测试代码里），或把文件放进 [AppDatabase.testDataDirectory]
///   后用相对路径。
String? resolveDataPathImpl(String path, {bool allowAbsolute = false}) {
  if (p.isAbsolute(path)) {
    if (!allowAbsolute) return null;
    return p.normalize(path);
  }
  return _resolveInsideDir(AppDatabase.dataDirectoryPath(), path);
}

/// B3-P01：库内文件相对路径是否合法（备份恢复校验用）。
/// 只允许 `imports/` 或 `slices/` 下的相对路径；空串表示“没有
/// 文件”（collect_tasks.source_path 的默认值就是 ''），也放行。
/// 拒绝：绝对路径、含盘符（`C:`）、`..` / `.` / 空段穿越。
/// 注意：`..` 即使最终仍落在数据目录内（如
/// `imports/../slices/x.png`）也拒绝——备份里的路径必须是
/// 干净的规范形式，含 `..` 一律视为可疑。
bool isAllowedDataRelativePathImpl(String value) {
  if (value.isEmpty) return true;
  final normalized = value.replaceAll('\\', '/');
  if (normalized.startsWith('/')) return false;
  if (p.isAbsolute(value) || normalized.contains(':')) return false;
  if (!normalized.startsWith('imports/') && !normalized.startsWith('slices/')) {
    return false;
  }
  for (final part in normalized.split('/')) {
    if (part.isEmpty || part == '..' || part == '.') return false;
  }
  return true;
}

/// B3-P01：任务 id 的安全字符集（删任务目录校验用）。
/// 只允许字母/数字/`_`/`-`；`../slices`、`..`、含 `/` 或 LIKE
/// 通配符（`%`/`_`）的 id 一律拒绝，绝不能靠“前缀检查”蒙混
/// （`imports/../slices` 规范化后就是 `slices/` 本身）。
final RegExp _safeTaskIdPattern = RegExp(r'^[A-Za-z0-9_-]+$');

/// §1.2(c)：框 id 规则 `box-<scope>-p<page>-<uuid16>`（v2.1 补丁定稿；
/// 草稿 scope 是任务 id，重框 scope 是 `rework-<questionId>`）。
/// SR-P2-12：随机段从 8 位十六进制（32 位熵）扩到 16 位（64 位熵）——
/// 旧 8 位在同一 (scope, page) 下框数上千时碰撞概率进入可感知区间
/// （生日悖论约 7 万个框 50%），而插框全用 REPLACE，碰撞会静默
/// 覆盖另一道框、不报错。16 位下同样量级可忽略；不引入 uuid 包
/// （P2 实施注意 3）。
String newBoxIdImpl(String scope, int page) {
  final r = math.Random.secure();
  final uuid16 = List.generate(
    16,
    (_) => '0123456789abcdef'[r.nextInt(16)],
  ).join();
  return 'box-$scope-p$page-$uuid16';
}

/// B4.3：新位置是否已有库文件（设置页切换前问“覆盖 / 保留”用）。
bool databaseExistsAtImpl(String dir) =>
    File(p.join(dir, 'quiz-master2.db')).existsSync();

/// 二十四批 D-253：默认数据目录的纯解析核心（平台、环境与路径
/// 风格均可注入，测试在 Linux 上覆盖 Windows/Android 分支）。
///
/// - Android：必须用启动时解析好的 [startupDataDirectory]（main()
///   里先用 path_provider 取应用内部存储目录）；未设或空串就抛
///   StateError，绝不回退到相对路径。
/// - Windows：LOCALAPPDATA → USERPROFILE\AppData\Local。
/// - 其他：XDG_DATA_HOME → HOME/.local/share。
///
/// 算出的结果若是相对路径一律抛 StateError（旧行为是静默返回
/// 相对路径，调用方再在进程当前目录下建目录——安卓上进程当前
/// 目录是只读的根目录 /，建 .local 直接报 errno 30；见 D-253）。
/// [pathContext] 默认当前平台风格；测试传 [p.windows]/[p.posix]
/// 覆盖跨平台分支。
@visibleForTesting
String resolveDefaultDataDirectory({
  required bool isWindows,
  required bool isAndroid,
  required String? startupDataDirectory,
  required Map<String, String> environment,
  p.Context? pathContext,
}) {
  final ctx = pathContext ?? p.context;
  final String result;
  if (isAndroid) {
    final dir = startupDataDirectory;
    if (dir == null || dir.isEmpty) {
      throw StateError(
        '安卓数据目录未初始化：启动时须先用 path_provider 解析应用内部存储目录，再设置 AppDatabase.startupDataDirectory。',
      );
    }
    result = ctx.join(dir, 'quiz-master2');
  } else if (isWindows) {
    final localAppData = environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      result = ctx.join(localAppData, 'quiz-master2');
    } else {
      result = ctx.join(
        environment['USERPROFILE'] ?? '',
        'AppData',
        'Local',
        'quiz-master2',
      );
    }
  } else {
    final xdg = environment['XDG_DATA_HOME'];
    if (xdg != null && xdg.isNotEmpty) {
      result = ctx.join(xdg, 'quiz-master2');
    } else {
      final home = environment['HOME'] ?? '';
      result = ctx.join(home, '.local', 'share', 'quiz-master2');
    }
  }
  if (!ctx.isAbsolute(result)) {
    throw StateError('数据目录算出来是相对路径（$result），拒绝使用。');
  }
  return result;
}

String _defaultDataDirectoryPath() => resolveDefaultDataDirectory(
  isWindows: Platform.isWindows,
  isAndroid: Platform.isAndroid,
  startupDataDirectory: AppDatabase.startupDataDirectory,
  environment: Platform.environment,
);

/// 数据目录内的相对路径解析（`..` 越界返回 null，不许读盘）。
String? _resolveInsideDir(String dataDir, String rel) {
  if (p.isAbsolute(rel)) return null;
  final base = p.normalize(dataDir);
  final abs = p.normalize(p.join(base, rel.replaceAll('\\', '/')));
  if (abs != base && !abs.startsWith('$base${p.separator}')) return null;
  return abs;
}

/// 库内存的路径 → 数据目录内的 `/` 分隔相对路径；越界或库外
/// 绝对路径返回 null（不是库管的文件，不参与备份/清理）。
String? _toDataRelative(String stored, String dataDir) {
  final base = p.normalize(dataDir);
  if (p.isAbsolute(stored)) {
    final abs = p.normalize(stored);
    if (!abs.startsWith('$base${p.separator}')) return null;
    return p.relative(abs, from: base).replaceAll('\\', '/');
  }
  final rel = stored.replaceAll('\\', '/');
  if (rel.startsWith('/')) return null;
  final abs = p.normalize(p.join(base, rel));
  if (abs != base && !abs.startsWith('$base${p.separator}')) return null;
  return p.relative(abs, from: base).replaceAll('\\', '/');
}

extension AppDatabasePaths on AppDatabase {
  /// 改数据库位置：写标记文件（下次启动生效，须重启）。
  /// SR-P2-7：三点修正——(a) 标记目录认测试隔离钩子
  /// [AppDatabase.testMarkerDirectory]（与 [AppDatabase.migrateToDirectory]
  /// 同一口径），测试调它不再改真实标记文件；(b) 先校验目录：
  /// 空串 / 不存在 / 不是目录一律拒绝，不写标记也不写设置；
  /// (c) 顺序改为先写设置、后写标记：标记写失败时把设置回滚到
  /// 旧值再抛错，不留“标记是旧目录、设置是新目录”的不一致。
  /// 旧写法是先写标记后写设置，后者失败时下次启动就用新目录、
  /// 与设置里记录的位置不一致。
  Future<void> setCustomDataDirectory(String dir) async {
    final trimmed = dir.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('数据库位置不能为空');
    }
    if (!Directory(trimmed).existsSync()) {
      throw StateError('数据库位置不存在：$trimmed');
    }
    final markerDir =
        AppDatabase.testMarkerDirectory ?? _defaultDataDirectoryPath();
    final markerFile = File(p.join(markerDir, 'db_location.txt'));
    final d = await db;
    // B2 集成：旧值读走 db_settings 的类型化读（原 SELECT value
    // FROM settings WHERE key = ?）。
    final oldSetting = await _settingValueInto(d, 'databaseLocation');
    await saveSetting('databaseLocation', trimmed);
    try {
      await Directory(markerDir).create(recursive: true);
      await markerFile.writeAsString(trimmed);
    } catch (e) {
      // 标记没写成：设置回滚到旧值（无旧值则删行），再抛原错。
      // B2 集成：回滚 DELETE 走 Drift 类型化删除；写回旧值仍走
      // saveSetting（已类型化）。回滚语义不变。
      try {
        if (oldSetting == null) {
          await (d.delete(
            d.settings,
          )..where((t) => t.key.equals('databaseLocation'))).go();
        } else {
          await saveSetting('databaseLocation', oldSetting);
        }
      } catch (_) {}
      rethrow;
    }
  }
}
