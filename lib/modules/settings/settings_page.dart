import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../data/badge_notifier.dart';
import '../../data/database.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../services/import_service.dart';
import '../../services/zip_archive.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/uikit.dart';

/// 设置：分段折叠式五组（外观 / 复习 / 错题本 / 数据 / 启动与关于），
/// 默认全折起，一次只展开一个。每项标题 + 一句短说明 + 选项，简洁直接。
/// 改设置后调 onSettingsChanged 保存并刷新主题 / 字体。
///
/// 结构与文案以 HTML 原型 `viewSettings()` 为准（R0 附录 A）：
/// 外观三段 + 问候语（保存/恢复默认，留空保存不生效）；复习含加入方式
/// 说明行、复查间隔/自查次数/每轮错因数/跳过次数/重做答案默认/通知
/// 开关 + 提醒时间/复习列表排序；错题本默认视图/排序/每页数量；
/// 数据备份/恢复（恢复先选文件再内联确认，含备份题数与当前题数）、
/// 数据库位置（改后提示重启才生效）、空间占用与孤儿清理（P3 §4.5：
/// 打开数据组时统计/扫描，清理前预览确认）、缓存清理（先预览临时文件数 +
/// 缩略图数 + 约多少 MB，再确认）、清除演示数据；启动页 + 关于
/// （版本 v0.1.0、作者 Meng（个人项目）、更新说明）。
/// 不做的项不出现：首页显示内容开关、封面计数牌开关、导入文件大小、
/// 整理台默认排序（与 HTML psub 的“不做”清单一致）。
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.repo,
    required this.settings,
    required this.onSettingsChanged,
    this.loadFailed = false,
    this.onBackupFailed,
  });

  final QuestionRepository repo;
  final AppSettings settings;
  final Future<void> Function(AppSettings s) onSettingsChanged;

  /// 设置读取失败时由 app 传入：显示错误横幅，已显示默认设置。
  final bool loadFailed;

  /// 待定3：手动备份失败时调用（应用层点亮首页红色横幅）。
  final VoidCallback? onBackupFailed;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _CachePreview {
  const _CachePreview({
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

class _SettingsPageState extends State<SettingsPage> {
  String? _openGroup;
  late AppSettings _s;
  final _greetingController = TextEditingController();
  bool _busy = false;
  bool _errorDismissed = false;
  bool _dbPendingRestart = false;
  // B4.3：本次改位置是否真的迁了库文件（迁了就是新位置已在用，
  // 提示语不能再说“重启前还是用现在这个位置”；“保留现有库”只是
  // 换了指向，重启前仍在用旧库，走旧提示语）。
  bool _dbMigrated = false;
  int _questionCount = 0;

  // 恢复：选好的备份文件（未确认前只记着，不动库）。
  String? _restoreFileName;
  Map<String, dynamic>? _restoreData;
  // P3 §2.3：zip 备份恢复——选好后只存路径，确认时再读文件恢复
  // （zip 可能很大，不常驻内存；老 JSON 备份沿用 _restoreData）。
  String? _restoreZipPath;

  // 空间占用与孤儿清理：只在打开数据组时扫描一次。
  ({int importsBytes, int slicesBytes})? _storageUsage;
  OrphanScan? _orphanScan;
  bool _orphanConfirm = false;

  // 迁移进度：搬库进行中显示百分比，可取消。
  bool _migrating = false;
  double _migrateProgress = 0;
  bool _migrateCancelled = false;

  // 缓存清理：只在打开数据组时扫描一次；清理完显示释放量，可重新扫描。
  _CachePreview? _cachePreview;
  bool _cacheScanned = false;
  String? _cacheCleanedMb;

  // 清空演示数据：内联确认。
  bool _confirmClearDemo = false;
  int _demoCountForConfirm = 0;

  Future<void> _askClearDemo() async {
    final count = await widget.repo.demoQuestionCount();
    if (count == 0) {
      _snack('没有演示数据');
      return;
    }
    setState(() {
      _demoCountForConfirm = count;
      _confirmClearDemo = true;
    });
  }

  @override
  void initState() {
    super.initState();
    _s = widget.settings;
    _greetingController.text = _s.greeting;
    _loadQuestionCount();
  }

  Future<void> _loadQuestionCount() async {
    try {
      final list = await widget.repo.all(includeArchived: true);
      if (!mounted) return;
      setState(() => _questionCount = list.length);
    } catch (_) {
      // 计数拿不到不影响设置页本身；恢复确认里只写备份题数。
    }
  }

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.settings.toMap().toString() != _s.toMap().toString()) {
      _s = widget.settings;
      _greetingController.text = _s.greeting;
    }
  }

  @override
  void dispose() {
    _greetingController.dispose();
    super.dispose();
  }

  Future<void> _apply(AppSettings s) async {
    setState(() => _s = s);
    await widget.onSettingsChanged(s);
  }

  void _toggleGroup(String key) {
    setState(() {
      _openGroup = _openGroup == key ? null : key;
      if (_openGroup == 'data' && !_cacheScanned) _scanCache();
      if (_openGroup == 'data') _scanStorageAndOrphans();
    });
  }

  /// P3 §4.5/§6 第 9 条：打开数据组时统计空间占用、扫描孤儿文件。
  /// 孤儿清理的提醒就放在这里：每次打开数据组，有孤儿就提示一次。
  Future<void> _scanStorageAndOrphans() async {
    try {
      final usage = await widget.repo.storageUsageBreakdown();
      if (!mounted) return;
      setState(() => _storageUsage = usage);
    } catch (_) {}
    try {
      final scan = await widget.repo.scanOrphanFiles();
      if (!mounted) return;
      setState(() => _orphanScan = scan);
    } catch (_) {}
  }

  /// P3 §4.5：孤儿清理——确认后执行，只删预览里列出的无引用文件。
  Future<void> _clearOrphans() async {
    final scan = _orphanScan;
    if (scan == null || scan.files.isEmpty) return;
    setState(() => _orphanConfirm = false);
    try {
      final result = await widget.repo.deleteOrphanFiles(
        scan.files.map((f) => f.relativePath).toList(),
      );
      if (!mounted) return;
      setState(() => _orphanScan = null);
      await _scanStorageAndOrphans();
      _snack(result.deletedCount == 0
          ? '没有可清理的无用文件'
          : '已清理 ${result.deletedCount} 个无用文件，'
              '释放 ${ImportService.formatBytes(result.freedBytes)}');
    } catch (_) {
      _snack('清理失败，稍后再试');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------- 问候语 ----------

  Future<void> _saveGreeting() async {
    final text = _greetingController.text.trim();
    if (text.isEmpty) {
      _snack('留空保存不生效');
      return;
    }
    await _apply(_s.copyWith(greeting: text));
    _snack('问候语已保存');
  }

  Future<void> _resetGreeting() async {
    _greetingController.text = '今天也要加油呀';
    await _apply(_s.copyWith(greeting: '今天也要加油呀'));
  }

  // ---------- 数据：备份 / 恢复 ----------

  /// 待定3：记一次备份失败——写库标志 + 通知应用层点亮首页横幅。
  /// 标志写失败也不影响本页的即时提示（静默跳过）。
  Future<void> _markBackupFailed() async {
    try {
      await widget.repo.setBackupFailed(true);
    } catch (_) {}
    widget.onBackupFailed?.call();
  }

  Future<void> _backup() async {
    setState(() => _busy = true);
    try {
      // P3 §2.3：备份改为 zip（JSON + imports/ + slices/），扩展名
      // 仍是 .qm2backup，内容改为 zip；恢复即完整（含题目图片）。
      final bytes = await widget.repo.exportBackupZip();
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '备份题库',
        // §2.3：v2 备份扩展名 .qm2backup（v1 选择器只允许 .json，
        // 正常流程下选不到 v2 备份；导出时提示仅新版可恢复）。
        fileName: 'quiz-master2-backup.qm2backup',
      );
      if (path == null) return;
      // B4.2：file_picker 8.3.7 的 saveFile 在桌面端只返回选好的路径，
      // 不写文件（bytes 参数只在移动端走通道写文件；Linux 实现直接
      // 忽略 bytes，macOS 传了还会抛错）——必须自己写文件。之前只
      // 传了 bytes 就弹“备份已保存”，实际上没有文件落盘，是旧 bug；
      // 本次修掉，否则 B4.2 的“备份→恢复”流程无文件可恢复。
      try {
        await File(path).writeAsBytes(bytes);
        // 待定3：备份成功，清掉之前可能留下的失败标志。
        try {
          await widget.repo.setBackupFailed(false);
        } catch (_) {}
        _snack('备份已保存（含题目图片，此备份仅新版可恢复）');
      } catch (_) {
        // 待定3：写文件失败 = 本次备份失败，记标志（首页出红横幅）；
        // 本页原有的即时提示保留。
        await _markBackupFailed();
        _snack('备份没存上，换个位置再试一次');
      }
    } catch (_) {
      // 导出备份或选路径本身失败（以前这里无 catch、异常直接外抛，
      // 既无提示也不留标志）：同样记一次备份失败。
      await _markBackupFailed();
      _snack('备份没存上，换个位置再试一次');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmRestore() async {
    final data = _restoreData;
    if (data == null) return;
    final zipPath = _restoreZipPath;
    setState(() {
      _busy = true;
      _restoreData = null;
      _restoreFileName = null;
      _restoreZipPath = null;
    });
    try {
      if (zipPath != null) {
        // P3 §2.3：zip 恢复（JSON + 文件一起恢复，失败回滚、原库不动）。
        await widget.repo.importBackupZipFile(zipPath);
      } else {
        // 老 JSON 备份（.qm2backup 但内容是 JSON）：走 JSON 恢复。
        await widget.repo.importBackupJson(data);
      }
      bumpBadgeVersion();
      final restored = await widget.repo.settings();
      await _apply(restored);
      await _loadQuestionCount();
      _snack('已恢复备份');
    } on BackupRestoreException catch (e) {
      // §2.3：校验不过拒绝恢复、原库不动；报具体原因（不是笼统的
      // “恢复失败”），恢复失败要向用户报错（以前是静默的 finally）。
      _snack(e.message);
    } catch (_) {
      _snack('恢复失败，备份文件可能已损坏，原题库没动');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickRestoreFile() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '选择备份文件',
      type: FileType.custom,
      // §2.3（任务定稿）：同时允许 .json 与 .qm2backup；.json 选到时
      // 按校验拒绝（_meta 缺失 → v1 备份不再支持），不要静默读坏。
      allowedExtensions: ['json', 'qm2backup'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    List<int> bytes;
    try {
      bytes = await File(path).readAsBytes();
    } catch (_) {
      _snack('这个备份文件打不开，换一个再试');
      return;
    }
    // P3 §2.3：按魔数识别，不靠扩展名——新 zip 备份以 PK 开头，
    // 老 .qm2backup JSON 内容是 JSON 文本；两者恢复口径不同，
    // 不要静默读坏。
    if (isZipBytes(bytes)) {
      Map<String, dynamic> data;
      try {
        data = AppDatabase.readBackupJsonFromZip(bytes);
      } on BackupRestoreException catch (e) {
        _snack(e.message);
        return;
      } catch (_) {
        _snack('这个文件不是 quiz-master2 的备份，恢复不了');
        return;
      }
      setState(() {
        _restoreFileName = result!.files.single.name;
        _restoreData = data;
        _restoreZipPath = path;
      });
      return;
    }
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      data = decoded;
      if (data['questions'] is! List || data['subjects'] is! List) {
        throw const FormatException();
      }
      // §2.3：选文件时先校验版本（_meta 缺失 / > 2 都拒绝），
      // 即时反馈；确认恢复时数据层再校验一次。
      AppDatabase.validateBackupData(data);
    } on BackupRestoreException catch (e) {
      _snack(e.message);
      return;
    } catch (_) {
      _snack('这个文件不是 quiz-master2 的备份，恢复不了');
      return;
    }
    setState(() {
      _restoreFileName = result!.files.single.name;
      _restoreData = data;
      _restoreZipPath = null;
    });
  }

  String get _dbPath {
    final used = widget.repo.db.dbPathUsed;
    if (used != null && used.isNotEmpty) return used;
    return '${AppDatabase.dataDirectoryPath()}${Platform.pathSeparator}quiz-master2.db';
  }

  /// B4.3：切换数据库位置时迁移旧库（复制旧库文件到新位置，不只写
  /// 标记）。新位置已有库文件时先问用户：覆盖（用当前题库替换新
  /// 位置的库）/ 保留现有库（直接用新位置原来的题库，当前题库留
  /// 在原位置不动）/ 取消。迁移失败提示且不丢旧库。
  Future<void> _changeDbLocation() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择数据库位置',
    );
    if (dir == null) return;
    if (!mounted) return;
    if (AppDatabase.databaseExistsAt(dir)) {
      final choice = await showDialog<String>(
        context: context,
        builder: (dctx) => AlertDialog(
          title: const Text('这个位置已经有题库了'),
          content: const Text(
              '新位置已经有一个 quiz-master2.db。覆盖会用现在的题库替换它（题库和图片一起搬过去；新位置原来的题库就没了）；保留会直接用新位置原来的题库，现在的题库留在原位置不动。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(null),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dctx).pop('keep'),
              child: const Text('保留现有库'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dctx).pop('overwrite'),
              child: const Text('覆盖'),
            ),
          ],
        ),
      );
      if (choice == null) return;
      if (choice == 'keep') {
        await widget.repo.setCustomDataDirectory(dir);
        if (!mounted) return;
        setState(() {
          _dbPendingRestart = true;
          _dbMigrated = false;
        });
        _snack('已切换到新位置原来的题库，重启后生效');
        return;
      }
      await _migrateDb(dir, overwrite: true);
      return;
    }
    await _migrateDb(dir, overwrite: false);
  }

  Future<void> _migrateDb(String dir, {required bool overwrite}) async {
    // P3 §4.6：搬库带进度与取消（大目录复制按字节回调进度）。
    setState(() {
      _migrating = true;
      _migrateProgress = 0;
      _migrateCancelled = false;
    });
    final outcome = await widget.repo.migrateToDirectory(
      dir,
      overwrite: overwrite,
      onProgress: (p) {
        if (mounted) setState(() => _migrateProgress = p);
      },
      isCancelled: () => _migrateCancelled,
    );
    if (!mounted) return;
    setState(() => _migrating = false);
    switch (outcome) {
      case DbMigrationOutcome.migrated:
        setState(() {
          _dbPendingRestart = true;
          _dbMigrated = true;
        });
        _snack('已把题库迁移到新位置，重启后生效');
      case DbMigrationOutcome.noSourceDb:
        setState(() {
          _dbPendingRestart = true;
          _dbMigrated = true;
        });
        _snack('新位置已保存，重启后生效');
      case DbMigrationOutcome.sameLocation:
        _snack('已经是这个位置了');
      case DbMigrationOutcome.targetExists:
        _snack('这个位置已经有题库了');
      case DbMigrationOutcome.cancelled:
        _snack('已取消迁移，仍用原来的题库');
      case DbMigrationOutcome.failed:
        _snack('迁移失败，仍用原来的题库');
    }
  }

  // ---------- 数据：缓存清理 ----------

  /// 缓存清理预览：临时文件 + 缩略图缓存 + 失败导入残留，不动题目数据。
  /// 递归扫数据目录下名字含 cache / thumb / tmp 的目录与 .tmp / .cache
  /// 文件，按类计数并合计字节数（HTML 预览口径，不照搬演示数字）。
  _CachePreview _scanCacheSync() {
    final dir = Directory(AppDatabase.dataDirectoryPath());
    var tempCount = 0;
    var thumbCount = 0;
    var failedCount = 0;
    var bytes = 0;
    final items = <FileSystemEntity>[];
    if (!dir.existsSync()) {
      return const _CachePreview(
          tempCount: 0,
          thumbCount: 0,
          failedCount: 0,
          bytes: 0,
          items: []);
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

    void walk(Directory d, {bool insideCacheDir = false}) {
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
          add(e, 'failed');
          continue;
        }
        if (e is Directory &&
            (lower.contains('cache') ||
                lower.contains('thumb') ||
                lower.contains('tmp'))) {
          // 目录整体计入：缩略图目录计缩略图，其余计临时文件。
          add(e, lower.contains('thumb') ? 'thumb' : 'temp');
          continue;
        }
        if (e is File) {
          if (lower.startsWith('thumb')) {
            add(e, 'thumb');
          } else if (lower.endsWith('.tmp') || lower.endsWith('.cache')) {
            add(e, 'temp');
          } else if (insideCacheDir) {
            add(e, 'temp');
          }
        }
      }
    }

    walk(dir);
    return _CachePreview(
      tempCount: tempCount,
      thumbCount: thumbCount,
      failedCount: failedCount,
      bytes: bytes,
      items: items,
    );
  }

  void _scanCache() {
    setState(() {
      _cachePreview = _scanCacheSync();
      _cacheScanned = true;
      _cacheCleanedMb = null;
    });
  }

  Future<void> _clearCache() async {
    final preview = _cachePreview;
    if (preview == null) return;
    var deleted = 0;
    for (final e in preview.items) {
      try {
        if (e is Directory) {
          await e.delete(recursive: true);
        } else {
          await e.delete();
        }
        deleted++;
      } catch (_) {
        // 单个删不掉就跳过，不中断。
      }
    }
    setState(() {
      _cacheCleanedMb = preview.mb;
      _cachePreview = _scanCacheSync();
    });
    _snack(deleted == 0 ? '没有可清理的缓存' : '已清理 $deleted 项缓存');
  }

  Future<void> _clearDemo() async {
    final n = await widget.repo.clearDemoData();
    setState(() => _confirmClearDemo = false);
    await _loadQuestionCount();
    _snack('已清空 $n 道演示题');
  }

  Future<void> _pickNotifyTime() async {
    final parts = _s.notifyTime.split(':');
    final initial = TimeOfDay(
      hour: int.tryParse(parts.elementAtOrNull(0) ?? '') ?? 20,
      minute: int.tryParse(parts.elementAtOrNull(1) ?? '') ?? 0,
    );
    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
    );
    if (picked == null) return;
    final text =
        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    await _apply(_s.copyWith(notifyTime: text));
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('设置', style: Theme.of(context).textTheme.titleLarge),
          SizedBox(height: 14 * scale),
          if (widget.loadFailed && !_errorDismissed)
            QmBanner(
              tone: QmBannerTone.error,
              message: '设置读取失败，已显示默认设置。修改前请先重启应用。',
              onDismiss: () => setState(() => _errorDismissed = true),
            ),
          QmFoldSection(
            title: '外观',
            expanded: _openGroup == 'appearance',
            onToggle: () => _toggleGroup('appearance'),
            child: _buildAppearance(),
          ),
          SizedBox(height: R10Tokens.settingsGroupGap * scale),
          QmFoldSection(
            title: '复习',
            expanded: _openGroup == 'review',
            onToggle: () => _toggleGroup('review'),
            child: _buildReview(),
          ),
          SizedBox(height: R10Tokens.settingsGroupGap * scale),
          QmFoldSection(
            title: '错题本',
            expanded: _openGroup == 'wrongbook',
            onToggle: () => _toggleGroup('wrongbook'),
            child: _buildWrongbook(),
          ),
          SizedBox(height: R10Tokens.settingsGroupGap * scale),
          QmFoldSection(
            title: '数据',
            expanded: _openGroup == 'data',
            onToggle: () => _toggleGroup('data'),
            child: _buildData(),
          ),
          SizedBox(height: R10Tokens.settingsGroupGap * scale),
          QmFoldSection(
            title: '启动与关于',
            expanded: _openGroup == 'startup',
            onToggle: () => _toggleGroup('startup'),
            child: _buildStartup(),
          ),
        ],
      ),
    );
  }

  /// 内联确认框（HTML `.confirmbox`；与学科管理页、详情页同款）。
  Widget _confirmBox({
    required String title,
    required String detail,
    required String confirmLabel,
    required VoidCallback onConfirm,
    required VoidCallback onCancel,
  }) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    return Container(
      margin: EdgeInsets.only(top: 10 * scale),
      padding: EdgeInsets.symmetric(
        horizontal: DesignTokens.detailConfirmPaddingH * scale,
        vertical: DesignTokens.detailConfirmPaddingV * scale,
      ),
      decoration: BoxDecoration(
        color: palette.errBg,
        border: Border.all(color: palette.errLine),
        borderRadius: BorderRadius.circular(
          DesignTokens.scaled(scale).radius,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              style: TextStyle(
                fontSize: DesignTokens.bannerFontSize,
                color: palette.errInk,
                height: DesignTokens.bodyLineHeight,
              ),
              children: [
                TextSpan(
                  text: title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (detail.isNotEmpty) TextSpan(text: detail),
              ],
            ),
          ),
          SizedBox(height: 8 * scale),
          Wrap(
            spacing: 8 * scale,
            runSpacing: 8 * scale,
            children: [
              QmButton(
                label: confirmLabel,
                size: QmButtonSize.small,
                onPressed: onConfirm,
              ),
              QmButton(
                label: '取消',
                variant: QmButtonVariant.plain,
                size: QmButtonSize.small,
                onPressed: onCancel,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 设置行：标题 + 一行短说明 + 右侧控件；窄屏时控件换到下一行。
  Widget _row(String title, String desc, Widget control) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final text = Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: R10Tokens.settingsRowTitleFontSize,
                  fontWeight: FontWeight.w700)),
          SizedBox(height: 2 * scale),
          Text(desc,
              style: TextStyle(
                  fontSize: R10Tokens.settingsRowDescFontSize,
                  color: palette.muted)),
        ],
      ),
    );
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 8 * scale),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 700 * scale) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [text]),
                SizedBox(height: 8 * scale),
                control,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              text,
              SizedBox(width: 16 * scale),
              control,
            ],
          );
        },
      ),
    );
  }

  Widget _segmented<T>({
    required T value,
    required List<QmSegmentOption<T>> options,
    required ValueChanged<T> onChanged,
  }) {
    return QmSegmented<T>(
      options: options,
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _noteText(String text) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Text(
      text,
      style: TextStyle(
        fontSize: R10Tokens.settingsRowDescFontSize,
        color: palette.muted,
      ),
    );
  }

  Widget _buildAppearance() {
    final scale = qmScaleOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _row(
          '主题',
          '跟随系统，或手动选浅色 / 深色。',
          _segmented<String>(
            value: _s.themeMode,
            options: const [
              QmSegmentOption(value: 'system', label: '跟随系统'),
              QmSegmentOption(value: 'light', label: '浅色'),
              QmSegmentOption(value: 'dark', label: '深色'),
            ],
            onChanged: (v) => _apply(_s.copyWith(themeMode: v)),
          ),
        ),
        _row(
          '字体大小',
          '标题、按钮和正文一起放大。',
          _segmented<String>(
            value: _s.fontSize,
            options: const [
              QmSegmentOption(value: 'standard', label: '标准'),
              QmSegmentOption(value: 'large', label: '大'),
              QmSegmentOption(value: 'extraLarge', label: '特大'),
            ],
            onChanged: (v) => _apply(_s.copyWith(fontSize: v)),
          ),
        ),
        _row(
          '首页问候语',
          '首页顶部显示的一句话，最长 40 字。',
          SizedBox(
            width: 400 * scale,
            child: Row(
              children: [
                Expanded(
                  child: QmTextField(
                    controller: _greetingController,
                    maxLength: 40,
                    onSubmitted: (_) => _saveGreeting(),
                  ),
                ),
                SizedBox(width: 8 * scale),
                QmButton(
                  label: '保存问候语',
                  size: QmButtonSize.small,
                  onPressed: _saveGreeting,
                ),
                SizedBox(width: 8 * scale),
                QmButton(
                  label: '恢复默认',
                  variant: QmButtonVariant.plain,
                  size: QmButtonSize.small,
                  onPressed: _resetGreeting,
                ),
              ],
            ),
          ),
        ),
        _noteText('首页现在显示的是：「${_s.greeting}」'),
      ],
    );
  }

  Widget _buildReview() {
    return Column(
      children: [
        _row(
          '加入方式',
          '手动加入：在题目详情点「加入复习」。',
          const SizedBox.shrink(),
        ),
        _row(
          '复查间隔',
          '错因解决后，隔几天复查。',
          _segmented<int>(
            value: _s.recheckIntervalDays,
            options: const [
              QmSegmentOption(value: 3, label: '3 天'),
              QmSegmentOption(value: 7, label: '7 天'),
              QmSegmentOption(value: 14, label: '14 天'),
            ],
            onChanged: (v) => _apply(_s.copyWith(recheckIntervalDays: v)),
          ),
        ),
        _row(
          '几次自查算已解决',
          '同一错因、同一道题，自查几次算已解决。',
          _segmented<int>(
            value: _s.cureChecks,
            options: const [
              QmSegmentOption(value: 1, label: '1 次'),
              QmSegmentOption(value: 2, label: '2 次'),
              QmSegmentOption(value: 3, label: '3 次'),
            ],
            onChanged: (v) => _apply(_s.copyWith(cureChecks: v)),
          ),
        ),
        _row(
          '每次复习解决几个错因',
          '一次解决几个，解决完出总结。',
          _segmented<int>(
            value: _s.causesPerSession,
            options: const [
              QmSegmentOption(value: 5, label: '5 个'),
              QmSegmentOption(value: 10, label: '10 个'),
              QmSegmentOption(value: 0, label: '不限'),
            ],
            onChanged: (v) => _apply(_s.copyWith(causesPerSession: v)),
          ),
        ),
        _row(
          '跳过几次留到下次',
          '第一次跳过放队尾，达到次数留到下次。',
          _segmented<int>(
            value: _s.skipLimit,
            options: const [
              QmSegmentOption(value: 1, label: '1 次'),
              QmSegmentOption(value: 2, label: '2 次'),
            ],
            onChanged: (v) => _apply(_s.copyWith(skipLimit: v)),
          ),
        ),
        _row(
          '重做时答案默认',
          '重做时答案藏着还是显示。',
          _segmented<bool>(
            value: _s.redoAnswerHidden,
            options: const [
              QmSegmentOption(value: true, label: '默认藏着'),
              QmSegmentOption(value: false, label: '默认显示'),
            ],
            onChanged: (v) => _apply(_s.copyWith(redoAnswerHidden: v)),
          ),
        ),
        _row(
          '通知提醒',
          '到复查时间时提醒，关了就不提醒。',
          _segmented<bool>(
            value: _s.notifyEnabled,
            options: const [
              QmSegmentOption(value: true, label: '开'),
              QmSegmentOption(value: false, label: '关'),
            ],
            onChanged: (v) => _apply(_s.copyWith(notifyEnabled: v)),
          ),
        ),
        _row(
          '提醒时间',
          '到复查那天，几点提醒。',
          QmButton(
            label: _s.notifyTime,
            variant: QmButtonVariant.secondary,
            size: QmButtonSize.small,
            onPressed: _s.notifyEnabled ? _pickNotifyTime : null,
          ),
        ),
        _row(
          '复习列表默认排序',
          '列表先按什么排。',
          _segmented<String>(
            value: _s.reviewSort,
            options: const [
              QmSegmentOption(value: 'joinTime', label: '按加入时间'),
              QmSegmentOption(value: 'subject', label: '按学科'),
            ],
            onChanged: (v) => _apply(_s.copyWith(reviewSort: v)),
          ),
        ),
      ],
    );
  }

  Widget _buildWrongbook() {
    return Column(
      children: [
        _row(
          '默认视图',
          '打开错题本时先显示哪种样子。',
          _segmented<String>(
            value: _s.wrongbookView,
            options: const [
              QmSegmentOption(value: 'large', label: '大卡片'),
              QmSegmentOption(value: 'compact', label: '紧凑列表'),
            ],
            onChanged: (v) => _apply(_s.copyWith(wrongbookView: v)),
          ),
        ),
        _row(
          '默认排序',
          '打开错题本时先按什么排。',
          _segmented<String>(
            value: _s.wrongbookSort,
            options: const [
              QmSegmentOption(value: 'new', label: '时间新 → 旧'),
              QmSegmentOption(value: 'old', label: '时间旧 → 新'),
              QmSegmentOption(value: 'subject', label: '学科首字母'),
            ],
            onChanged: (v) => _apply(_s.copyWith(wrongbookSort: v)),
          ),
        ),
        _row(
          '每页显示数量',
          '错题本和复习列表每页显示几道题。',
          _segmented<int>(
            value: _s.pageSize,
            options: const [
              QmSegmentOption(value: 10, label: '10'),
              QmSegmentOption(value: 20, label: '20'),
              QmSegmentOption(value: 30, label: '30'),
              QmSegmentOption(value: 40, label: '40'),
              QmSegmentOption(value: 50, label: '50'),
            ],
            onChanged: (v) => _apply(_s.copyWith(pageSize: v)),
          ),
        ),
      ],
    );
  }

  Widget _buildData() {
    final scale = qmScaleOf(context);
    final preview = _cachePreview;
    final pendingQuestions =
        (_restoreData?['questions'] as List?)?.length ?? 0;
    // P3 §6 第 9 条：空间占用与上限提示（打开数据组时统计）。
    final storageTotal = _storageUsage == null
        ? null
        : _storageUsage!.importsBytes + _storageUsage!.slicesBytes;
    final storageWarning = storageTotal == null
        ? null
        : ImportService.storageLimitMessage(storageTotal);
    final orphanScan = _orphanScan;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _row(
          '备份',
          '把题库导出为一个备份文件（.qm2backup，含题目图片），换电脑时用备份文件恢复。此备份仅新版可恢复。',
          QmButton(
            label: '备份题库',
            size: QmButtonSize.small,
            onPressed: _busy ? null : _backup,
          ),
        ),
        _row(
          '恢复',
          '恢复会覆盖当前题库，选完文件先确认。',
          QmButton(
            label: '选择备份文件…',
            variant: QmButtonVariant.secondary,
            size: QmButtonSize.small,
            onPressed: _busy ? null : _pickRestoreFile,
          ),
        ),
        if (_restoreData != null)
          _confirmBox(
            title: '恢复会覆盖当前题库，确定吗？',
            detail:
                '将用备份文件「${_restoreFileName ?? '备份文件'}」（$pendingQuestions 道题）覆盖现在的题库（当前 $_questionCount 道题）：现在的题会被替换掉，覆盖后找不回来。确定恢复吗？',
            confirmLabel: '确认恢复，覆盖当前题库',
            onConfirm: _confirmRestore,
            onCancel: () => setState(() {
              _restoreData = null;
              _restoreFileName = null;
              _restoreZipPath = null;
            }),
          ),
        _row(
          '数据库位置',
          '数据库文件 quiz-master2.db 就放在这个文件夹里，全部题和设置都存在里面。改完位置，要重启软件才生效。',
          SizedBox(
            width: 320 * scale,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SelectableText(
                  _dbPath,
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.right,
                ),
                SizedBox(height: 6 * scale),
                QmButton(
                  label: '改位置',
                  variant: QmButtonVariant.secondary,
                  size: QmButtonSize.small,
                  onPressed: _migrating ? null : _changeDbLocation,
                ),
              ],
            ),
          ),
        ),
        if (_dbPendingRestart)
          _noteText(_dbMigrated
              ? '新位置已保存：题库已迁过去，重启后彻底生效。'
              : '新位置已保存：要重启软件才生效——重启后才会改用新位置存数据库，重启前还是用现在这个位置。'),
        if (_migrating)
          _noteText(
              '正在迁移…${(_migrateProgress * 100).toStringAsFixed(0)}%（题库和图片一起搬，搬完前不要退出）。'),
        if (_migrating)
          QmButton(
            label: '取消迁移',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: () => setState(() => _migrateCancelled = true),
          ),
        _row(
          '空间占用',
          _storageUsage == null
              ? '正在统计…'
              : '题图与原图共占 ${ImportService.formatBytes(storageTotal!)}'
                  '（原图 ${ImportService.formatBytes(_storageUsage!.importsBytes)}、'
                  '切片 ${ImportService.formatBytes(_storageUsage!.slicesBytes)}），上限 2GB。',
          const SizedBox.shrink(),
        ),
        if (storageWarning != null) _noteText(storageWarning),
        _row(
          '孤儿清理',
          orphanScan == null
              ? '正在扫描无用文件…'
              : orphanScan.files.isEmpty
                  ? '没有无用文件（所有图片都有题目在用）。'
                  : '发现 ${orphanScan.count} 个无用文件，共约 ${ImportService.formatBytes(orphanScan.totalBytes)}：删题、删学科后留下的旧图片。清理只删这些没人用的文件，题目图片不会动。',
          QmButton(
            label: '清理无用文件',
            size: QmButtonSize.small,
            onPressed: orphanScan == null || orphanScan.files.isEmpty
                ? null
                : () => setState(() => _orphanConfirm = true),
          ),
        ),
        if (_orphanConfirm && orphanScan != null && orphanScan.files.isNotEmpty)
          _confirmBox(
            title: '清理无用文件，确定吗？',
            detail:
                '将删掉 ${orphanScan.count} 个没人用的文件（共约 ${ImportService.formatBytes(orphanScan.totalBytes)}），题目和数据不动，删了找不回来。确定清理吗？',
            confirmLabel: '确认清理',
            onConfirm: _clearOrphans,
            onCancel: () => setState(() => _orphanConfirm = false),
          ),
        _row(
          '清理缓存',
          preview == null
              ? '正在扫描缓存…'
              : _cacheCleanedMb != null
                  ? '已清理完成，释放 ${_cacheCleanedMb!} MB，题目和数据未动。'
                  : preview.totalCount == 0
                      ? '现在没有可清理的缓存。'
                      : '临时文件 ${preview.tempCount} 个、缩略图缓存 ${preview.thumbCount} 张，共约 ${preview.mb} MB；清理不影响题目和数据。',
          QmButton(
            label: _cacheCleanedMb != null ? '重新扫描' : '清理缓存',
            size: QmButtonSize.small,
            onPressed: preview == null
                ? null
                : _cacheCleanedMb != null
                    ? _scanCache
                    : preview.totalCount == 0
                        ? null
                        : () => _clearCache(),
          ),
        ),
        if (preview != null &&
            preview.totalCount > 0 &&
            _cacheCleanedMb == null)
          _noteText(preview.failedCount > 0
              ? '其中含导入失败的残留文件 ${preview.failedCount} 个，缩略图之后用到时会自动重新生成。'
              : '缩略图之后用到时会自动重新生成。'),
        _row(
          '演示数据',
          '清空全部演示数据：数学 / 英语 / 政治三科的演示题会被删掉。这个入口只放在设置里，首页没有这个按钮。',
          QmButton(
            label: '清空演示数据',
            variant: QmButtonVariant.danger,
            size: QmButtonSize.small,
            onPressed: _askClearDemo,
          ),
        ),
        if (_confirmClearDemo)
          _confirmBox(
            title: '清空演示数据，确定吗？',
            detail:
                '三科共 $_demoCountForConfirm 道演示题会全部删掉，删了就没了，确定吗？',
            confirmLabel: '确认清空',
            onConfirm: _clearDemo,
            onCancel: () => setState(() => _confirmClearDemo = false),
          ),
      ],
    );
  }

  Widget _kvRow(String label, String value) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 5 * scale),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: R10Tokens.kvLabelWidth * scale,
            child: Text(label,
                style: TextStyle(
                    fontSize: R10Tokens.kvFontSize,
                    fontWeight: FontWeight.w700,
                    color: palette.ink)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    fontSize: R10Tokens.kvFontSize, color: palette.ink2)),
          ),
        ],
      ),
    );
  }

  Widget _buildStartup() {
    return Column(
      children: [
        _row(
          '启动页',
          '打开应用时先到哪一页。',
          _segmented<String>(
            value: _s.startupPage,
            options: const [
              QmSegmentOption(value: 'home', label: '首页'),
              QmSegmentOption(value: 'last', label: '上次停下的页面'),
            ],
            onChanged: (v) => _apply(_s.copyWith(startupPage: v)),
          ),
        ),
        _row(
          '关于',
          '版本与更新说明。',
          const SizedBox.shrink(),
        ),
        _kvRow('版本', 'quiz-master2 v0.1.0'),
        _kvRow('作者', 'Meng（个人项目）'),
        _kvRow('更新说明',
            'v0.1.0：首个版本。错题收集 → 整理 → 按错因复习的主流程；学科管理定稿：学科 / 知识点树 / 标签 / 试卷可增删改，删学科删题，改名同步到题；文件夹只在错题本目录页管，删知识点 / 标签 / 试卷只让题上对应项变空（待补充）；主题默认跟随系统、可手动选亮 / 深，字体标准 / 大 / 特大三档；错题本目录页可增删改查文件夹，题可单个 / 批量移入其他文件夹。'),
      ],
    );
  }
}
