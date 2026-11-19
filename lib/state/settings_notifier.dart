import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/file_lifecycle_guard.dart';
import '../data/repository.dart';
import '../models/exam_event.dart';
import '../models/models.dart';
import '../services/zip_archive.dart';
import 'repository_provider.dart';

/// 设置状态的 Provider（ARCH-PLAN-A 第 1 阶段）。
///
/// 状态是 [AppSettings]（主题 / 字号 / 问候语 / 复习参数 / 错题本默认
/// 值 / 启动页等全部业务设置），唯一真源仍是 SQLite 的 settings 表；
/// 本 Provider 只做“响应式读取 + 写回”，不另存一份。
///
/// - 读：`ref.watch(settingsProvider)`（页面 / 根组件）；
/// - 写：`ref.read(settingsProvider.notifier).saveSettings(s)`
///   ——写库成功后才把 state 置为新值，写库失败 state 不动。
/// - 恢复备份后设置表可能被整体覆盖，用 [SettingsNotifier.reloadSettings]
///   从库里重读一次（代替 Stage 0 的 loadSettings + _apply 两步）。
///
/// 除状态本身外，本类完整保留 Stage 0 [SettingsController] 的全部业务
/// 方法（方法签名尽量复用，见 D-33）：问候语校验、备份/恢复编排、
/// 数据库位置与迁移、空间占用与孤儿清理、缓存扫描/清理、考试事件
/// 增删改。方法只返回结果或抛异常：弹窗、选文件对话框、SnackBar、
/// 导航等 UI 副作用全部留在 `settings_page.dart`。
/// 考试事件列表是懒加载的页面本地展示状态（只在考试组打开时读），
/// 增删改同样走本类的 [addExamEvent] / [renameExamEvent] /
/// [changeExamEventDate] / [deleteExamEvent]。
final settingsProvider = AsyncNotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

/// 设置页业务逻辑 + 设置状态（ARCH-PLAN-A 第 1 阶段：Stage 0 的
/// 纯 Dart 类 `SettingsController` 改为 `AsyncNotifier`）。
///
/// 拿库的方式变了：不再由构造器接 [QuestionRepository]，
/// 改为经 `ref.read(repositoryProvider)` 拿——测试注入见
/// `docs/ui-replication/A-READING-GUIDE.md`（`ProviderContainer.test`
/// + `repositoryProvider.overrideWithValue`）。
/// 备份恢复（GPT-P1）：解析时读到的字节一路带到确认恢复，恢复直接
/// 用这份字节，不再按路径重读——磁盘上的文件在解析后被替换/删除也
/// 不影响，恢复的永远是用户选中的那一份（旧 FR-43 指纹重查已删除，
/// 它正是 TOCTOU 窗口本身：校验与恢复是两次独立读文件）。
class SettingsNotifier extends AsyncNotifier<AppSettings> {
  /// 每次用都经 ref 拿：方法在 build() 跑完之前也能调（单测里只调
  /// 方法、不读 state 时尤其如此），且不缓存一份可能过期的 repo。
  QuestionRepository get _repo => ref.read(repositoryProvider);

  @override
  Future<AppSettings> build() => _repo.settings();

  /// 保存一组设置：先写库，成功后才更新 state（根组件与设置页经
  /// `ref.watch(settingsProvider)` 同时看到新值）。
  /// 写库失败抛异常，state 保持旧值——这是设置页与根组件唯一
  /// 的保存路径（Stage 0 的 `_apply` + `onSettingsChanged` 已合并
  /// 到这里，见 D-33 注意 ①）。
  Future<void> saveSettings(AppSettings s) async {
    await _repo.saveSettings(s);
    state = AsyncData(s);
  }

  /// 从库里重读设置（恢复备份后用：恢复可能覆盖了设置表）。
  /// `AsyncValue.guard` 的结果在读完后才一次性赋值，中间没有
  /// loading 态，根组件与设置页不会因此闪回启动屏 / 转圈。
  Future<void> reloadSettings() async {
    state = await AsyncValue.guard(() => _repo.settings());
  }

  /// 首页问候语默认值（与设置页“恢复默认”共用同一文案）。
  static const String defaultGreetingText = '今天也要加油呀';

  // ---------- 读库 ----------

  /// 考试事件列表（按日期升序，见 [QuestionRepository.examEvents]）。
  Future<List<ExamEvent>> loadExamEvents() => _repo.examEvents();

  /// 当前题库总题数（含已归档；恢复确认文案用）。
  Future<int> loadQuestionCount() async =>
      (await _repo.all(includeArchived: true)).length;

  // ---------- 问候语（纯函数，不碰库） ----------

  /// 校验并拼出要保存的设置：留空抛 [SettingsValidationException]，
  /// 调用方按异常的 message 提示（原页内文案“留空保存不生效”）。
  AppSettings greetingToSave(AppSettings current, String rawText) {
    final text = rawText.trim();
    if (text.isEmpty) {
      throw const SettingsValidationException('留空保存不生效');
    }
    return current.copyWith(greeting: text);
  }

  /// 恢复默认问候语。
  AppSettings defaultGreeting(AppSettings current) =>
      current.copyWith(greeting: defaultGreetingText);

  // ---------- 备份 / 恢复 ----------

  /// 导出 zip 备份的字节（JSON + imports/ + slices/）；写文件、
  /// 选保存位置由页面做（文件选择器是 UI 副作用）。
  Future<List<int>> exportBackupBytes() => _repo.exportBackupZip();

  /// 十四批 M2：带警告的 zip 导出（字节 + 可见警告列表，警告列出
  /// 缺失/不可读图块的题目）。设置页走这条。
  Future<({List<int> bytes, List<String> warnings})>
  exportBackupBytesWithReport() => _repo.exportBackupZipWithReport();

  /// 记一次备份失败（写库标志；页面再调 onBackupFailed 通知应用层）。
  Future<void> markBackupFailed() => _repo.setBackupFailed(true);

  /// 备份成功：清掉之前可能留下的失败标志。
  Future<void> clearBackupFailedFlag() => _repo.setBackupFailed(false);

  /// 解析用户选好的备份文件：读字节 → 按魔数识别 zip / JSON →
  /// 校验版本。返回备份数据与 zip 字节（zip 备份返回解析时读到的
  /// 完整字节，确认恢复时直接用这份字节，不再按路径重读；
  /// 老 JSON 备份 zipBytes 为 null，按数据对象恢复）。
  ///
  /// 读不到文件抛 [RestoreFileReadException]；zip 内容或 JSON
  /// 校验不过抛 [BackupRestoreException]（message 即提示文案）；
  /// 其余格式问题抛 [FormatException]。调用方按异常类型提示，
  /// 不做静默读坏。
  Future<({Map<String, dynamic> data, List<int>? zipBytes})>
  parseRestoreFile(String path) async {
    List<int> bytes;
    try {
      bytes = await File(path).readAsBytes();
    } catch (_) {
      throw RestoreFileReadException(path);
    }
    if (isZipBytes(bytes)) {
      // 新 zip 备份：只读出内嵌 JSON 校验，字节本身留给确认恢复用。
      final data = AppDatabase.readBackupJsonFromZip(bytes);
      return (data: data, zipBytes: bytes);
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) throw const FormatException();
    final data = decoded;
    if (data['questions'] is! List || data['subjects'] is! List) {
      throw const FormatException();
    }
    AppDatabase.validateBackupData(data);
    return (data: data, zipBytes: null);
  }

  /// 执行恢复（覆盖当前题库）：zip 备份按解析时读到的字节恢复
  /// （GPT-P1：校验过的字节与导入的字节是同一份，不再按路径重读），
  /// 老 JSON 备份按数据对象恢复。失败抛异常，原库不动。
  /// 十四批 M2：返回恢复警告列表（缺失/不可读的图块已从引用里去掉）。
  /// 恢复后调用方再调 [reloadSettings] 重读设置（恢复可能覆盖设置表）。
  Future<List<String>> restoreBackup({
    Map<String, dynamic>? jsonData,
    List<int>? zipBytes,
  }) async {
    if (zipBytes != null) {
      return _repo.importBackupZip(zipBytes);
    } else {
      await _repo.importBackupJson(jsonData!);
      return const [];
    }
  }

  // ---------- 数据库位置 / 迁移 ----------

  /// 当前正在用的数据库文件完整路径。
  String get dbPath {
    final used = _repo.db.dbPathUsed;
    if (used != null && used.isNotEmpty) return used;
    return '${AppDatabase.dataDirectoryPath()}${Platform.pathSeparator}quiz-master2.db';
  }

  /// 目标目录下是否已有题库文件（有则页面先问用户覆盖 / 保留 / 取消）。
  bool databaseExistsAt(String dir) => AppDatabase.databaseExistsAt(dir);

  /// 保留新位置原来的库：只换指向，当前题库留原位置不动。
  Future<void> keepExistingDatabase(String dir) =>
      _repo.setCustomDataDirectory(dir);

  /// 搬库（复制旧库文件 + 图片目录到新位置，带进度与取消）。
  Future<DbMigrationOutcome> migrateDatabase(
    String dir, {
    required bool overwrite,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) => _repo.migrateToDirectory(
    dir,
    overwrite: overwrite,
    onProgress: onProgress,
    isCancelled: isCancelled,
  );

  // ---------- 空间占用与孤儿清理 ----------

  /// 空间占用分项（原图 / 切片字节数）。
  Future<({int importsBytes, int slicesBytes})> storageUsage() =>
      _repo.storageUsageBreakdown();

  /// 扫描无引用文件（imports/ + slices/ 里的孤儿）。
  Future<OrphanScan> scanOrphans() => _repo.scanOrphanFiles();

  /// 只删传入的无引用文件，返回实际删掉的数量、释放字节数与
  /// 删除前重算引用后跳过的数量（FR-06(a)）。
  Future<({int deletedCount, int freedBytes, int skippedReferencedCount})>
  clearOrphans(List<String> relativePaths) =>
      _repo.deleteOrphanFiles(relativePaths);

  // ---------- 缓存扫描 / 清理 ----------

  /// 扫描缓存预览（临时文件 + 缩略图缓存 + 失败导入残留，不动题目数据）。
  CachePreview scanCache() => _scanCacheSync();

  /// 删掉预览里列出的全部缓存项，返回实际删掉的项数（单个删不掉跳过）。
  /// 十四批 M2（P2-2）：经统一文件操作锁（缓存项是临时文件/缩略图/
  /// 失败导入残留，不在题目引用集合里；取锁只是审计口径统一）。
  Future<int> clearCache(CachePreview preview) async {
    var deleted = 0;
    final guard = FileLifecycleGuard.instance;
    for (final e in preview.items) {
      try {
        var ok = false;
        if (e is Directory) {
          await guard.deleteDirectory(e);
          ok = !e.existsSync();
        } else if (e is File) {
          ok = await guard.deleteFile(e);
        } else {
          // 链接等其它实体：缓存里基本不出现，同样经统一文件操作锁
          // 直删（十四批 M5 修复轮 2：原 `await e.delete()` 不经锁，
          // 按 P2-2“全部物理删除集中接入”补上；clearCache 本身不持锁，
          // 无重入问题）。
          await guard.withLock(() async => e.delete());
          ok = !e.existsSync();
        }
        if (ok) deleted++;
      } catch (_) {
        // 单个删不掉就跳过，不中断。
      }
    }
    return deleted;
  }

  // ---------- 考试事件（B11-9，独立数据，与试卷无任何关联） ----------

  /// 新增一场考试：只填自定义名称 + 考试日期。名称留空、未选日期、
  /// 重名时抛 [SettingsValidationException]（message 即提示文案）；
  /// 写库失败时原异常外抛。返回写好的事件。
  Future<ExamEvent> addExamEvent({
    required List<ExamEvent> existing,
    required String name,
    required DateTime? date,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const SettingsValidationException('先填一个考试名称');
    }
    if (date == null) {
      throw const SettingsValidationException('先选一个考试日期');
    }
    if (existing.any((e) => e.name == trimmed)) {
      throw const SettingsValidationException('已经有了这场考试');
    }
    final event = ExamEvent(
      id: 'exam-event-${DateTime.now().millisecondsSinceEpoch}',
      name: trimmed,
      // 日期只存年月日：页面传进来的已是 dateOnly 归一化过的日期，
      // 这里再归一化一次只是兜底（原页内行为不变）。
      date: dateOnly(date),
    );
    await _repo.saveExamEvent(event);
    return event;
  }

  /// 改名：同名（除自身外）时抛 [SettingsValidationException]；
  /// 空名 / 与原名相同由页面在调之前拦下（弹窗取消的静默返回）。
  Future<void> renameExamEvent({
    required ExamEvent event,
    required String newName,
    required List<ExamEvent> existing,
  }) async {
    final trimmed = newName.trim();
    if (existing.any((x) => x.id != event.id && x.name == trimmed)) {
      throw const SettingsValidationException('已经有了这场考试');
    }
    await _repo.saveExamEvent(event.copyWith(name: trimmed));
  }

  /// 改日期（日期相同由页面在调之前拦下）。
  Future<void> changeExamEventDate(ExamEvent event, DateTime date) =>
      _repo.saveExamEvent(event.copyWith(date: dateOnly(date)));

  /// 删除一场考试：只删事件本身，不动任何题目 / 试卷。
  Future<void> deleteExamEvent(String id) => _repo.deleteExamEvent(id);
}

/// 设置页业务校验失败：[message] 即直接展示给用户的提示文案。
class SettingsValidationException implements Exception {
  const SettingsValidationException(this.message);

  final String message;

  @override
  String toString() => 'SettingsValidationException: $message';
}

/// 备份文件读不到（文件被删 / 无权限等），与“文件不是备份”区分提示。
/// FR-43：定义已移到数据层（`lib/data/database.dart` 的
/// [RestoreFileReadException]）；这里不再重复定义。恢复不再按路径
/// 重读文件（GPT-P1：解析时读到的字节一路带到恢复）。

/// 缓存清理预览：临时文件 + 缩略图缓存 + 失败导入残留，不动题目数据。
class CachePreview {
  const CachePreview({
    required this.tempCount,
    required this.thumbCount,
    required this.failedCount,
    required this.bytes,
    required this.items,
  });

  final int tempCount;
  final int thumbCount;
  final int failedCount;
  final int bytes;
  final List<FileSystemEntity> items;

  int get totalCount => tempCount + thumbCount + failedCount;
  String get mb => (bytes / (1024 * 1024)).toStringAsFixed(1);
}

/// 缓存清理预览：递归扫数据目录下名字含 cache / thumb / tmp 的目录
/// 与 .tmp / .cache 文件，按类计数并合计字节数（HTML 预览口径，
/// 不照搬演示数字）。
CachePreview _scanCacheSync() {
  final dir = Directory(AppDatabase.dataDirectoryPath());
  var tempCount = 0;
  var thumbCount = 0;
  var failedCount = 0;
  var bytes = 0;
  final items = <FileSystemEntity>[];
  if (!dir.existsSync()) {
    return const CachePreview(
      tempCount: 0,
      thumbCount: 0,
      failedCount: 0,
      bytes: 0,
      items: [],
    );
  }
  void add(FileSystemEntity e, String kind) {
    items.add(e);
    if (e is File) {
      try {
        bytes += e.lengthSync();
      } catch (_) {}
    } else if (e is Directory) {
      try {
        for (final f in e.listSync(recursive: true)) {
          if (f is File) bytes += f.lengthSync();
        }
      } catch (_) {}
    }
    switch (kind) {
      case 'thumb':
        thumbCount++;
      case 'failed':
        failedCount++;
      default:
        tempCount++;
    }
  }

  void walk(Directory d, {bool insideCacheDir = false, String? cacheKind}) {
    List<FileSystemEntity> entries;
    try {
      entries = d.listSync();
    } catch (_) {
      return;
    }
    for (final e in entries) {
      final name = e.path.split(Platform.pathSeparator).last;
      if (name == 'quiz-master2.db') continue;
      final lower = name.toLowerCase();
      if (lower.contains('failed') || lower.contains('import-error')) {
        // SR3-19：failed 目录也与 cache 分支同款——递归进去、文件逐个计，
        // 目录本身不再按 1 项算（B6 只改了 cache/thumb/tmp 分支）。
        // 之后 preview.items 里只有文件，与“不再有目录本身”对齐。
        if (e is Directory) {
          try {
            for (final f in e.listSync(recursive: true)) {
              if (f is File) add(f, 'failed');
            }
          } catch (_) {}
        } else {
          add(e, 'failed');
        }
        continue;
      }
      if (e is Directory &&
          (lower.contains('cache') ||
              lower.contains('thumb') ||
              lower.contains('tmp'))) {
        // SR2-30：cache/thumb/tmp 目录不再整体按 1 个计——递归进去，
        // 里面的文件逐个按类计数（thumb 目录里的按缩略图计，其余按
        // 临时文件计）；目录本身不再单独计 1，避免个数偏小。
        // 旧代码在这里 add() 后 continue，`insideCacheDir` 从未为
        // true，目录里的文件一个都没数上（8 个文件只算出 4 项）。
        walk(
          e,
          insideCacheDir: true,
          cacheKind: lower.contains('thumb') ? 'thumb' : 'temp',
        );
        continue;
      }
      if (e is File) {
        if (lower.startsWith('thumb')) {
          add(e, 'thumb');
        } else if (lower.endsWith('.tmp') || lower.endsWith('.cache')) {
          add(e, 'temp');
        } else if (insideCacheDir) {
          add(e, cacheKind ?? 'temp');
        }
      } else if (e is Directory) {
        // 普通子目录也要递归进入（SR-P2-50）：以前只扫顶层一层，
        // 藏在某子目录下的 cache/thumb/tmp 目录不会被发现，
        // 预览数字偏小、清理也删不到它们。
        walk(e, insideCacheDir: insideCacheDir, cacheKind: cacheKind);
      }
    }
  }

  walk(dir);
  return CachePreview(
    tempCount: tempCount,
    thumbCount: thumbCount,
    failedCount: failedCount,
    bytes: bytes,
    items: items,
  );
}
