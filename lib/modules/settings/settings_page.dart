import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../models/exam_event.dart';
import '../../models/models.dart';
import '../../services/import_service.dart';
import '../../services/ocr_key_store.dart';
import '../../services/ocr_queue.dart';
import '../../state/settings_notifier.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/uikit.dart';

/// D-173：恢复成功文案——只有恢复前确实存在未完成复习会话时才提
/// “已清除未完成的复习会话”；没有会话时只说“恢复成功”，不让用户
/// 误以为丢了数据。图块警告有则照旧追加（与旧文案同一口径）。
String restoreSuccessMessage({
  required bool hadUnfinishedSession,
  required List<String> warnings,
}) {
  final base = hadUnfinishedSession ? '恢复成功，已清除未完成的复习会话' : '恢复成功';
  return warnings.isEmpty ? base : '$base；${warnings.join('；')}';
}

/// 设置：分段折叠式六组（外观 / 复习 / 错题本 / 考试 / 数据 / 启动与关于），
/// 默认全折起，一次只展开一个。每项标题 + 一句短说明 + 选项，简洁直接。
/// 改设置后经 `settingsProvider`（见 lib/state/settings_notifier.dart）
/// 写库并刷新主题 / 字体——设置页与根组件读的是同一个 Provider，
/// 不再各传各的快照（ARCH-PLAN-A 第 1 阶段，见 D-34）。
/// 折叠组展开/收起、输入框内容、迁移进度等纯界面临时状态仍留页面
/// 本地 State，不进 Provider。
///
/// 结构与文案以 HTML 原型 `viewSettings()` 为准（R0 附录 A）：
/// 外观三段 + 问候语（保存/恢复默认，留空保存不生效）；复习含加入方式
/// 说明行、复查间隔/自查次数/每轮错因数/跳过次数/重做答案默认/通知
/// 开关 + 提醒时间/复习列表排序；错题本默认视图/排序/每页数量；
/// 数据备份/恢复（恢复先选文件再弹窗确认，含备份题数与当前题数）、
/// 数据库位置（改后提示重启才生效）、空间占用与孤儿清理（P3 §4.5：
/// 打开数据组时统计/扫描，清理前预览确认）、缓存清理（先预览临时文件数 +
/// 缩略图数 + 约多少 MB，再确认）、BigModel key（M6：OCR 服务凭据，
/// 密码式输入、只显示已设置/未设置）；启动页 + 关于
/// （版本 v0.1.0、作者 Meng（个人项目）、更新说明）。
/// 不做的项不出现：首页显示内容开关、封面计数牌开关、导入文件大小、
/// 整理台默认排序（与 HTML psub 的“不做”清单一致）。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({
    super.key,
    this.loadFailed = false,
    this.onBackupFailed,
    this.initialOpenGroup,
    // M6：BigModel key 存储。生产默认走平台安全存储（OcrKeyStore
    // 默认后端）；单测传内存假后端，不碰平台通道。
    this.keyStore,
  });

  /// 设置读取失败时由 app 传入：显示错误横幅，已显示默认设置。
  final bool loadFailed;

  /// 待定3：手动备份失败时调用（应用层点亮首页红色横幅）。
  final VoidCallback? onBackupFailed;

  /// B11-9：从首页倒计时点进来时直接展开的组（'exams'）；平时为空，
  /// 各组默认全折。组键与 [_SettingsPageState._openGroup] 同一套：
  /// 'appearance' / 'review' / 'wrongbook' / 'exams' / 'data' /
  /// 'startup'。
  final String? initialOpenGroup;

  /// M6：BigModel key 存储（可注入，见构造参数注释）。为 null 时
  /// State 里建默认实例（生产走 flutter_secure_storage）。
  final OcrKeyStore? keyStore;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  // Stage 1：业务逻辑在 SettingsNotifier（经 settingsProvider 拿），
  // 页面只留 setState 转发与 UI 副作用（弹窗、选文件对话框、
  // SnackBar、导航），见 D-34。_s 是 Provider 值的本地镜像：
  // build 里 watch 到新值时同步过来（问候语输入框的 controller
  // 文本同时跟进）；_apply 只调 notifier.saveSettings，不再
  // 自己 setState——Provider 重建会把新值带回来。
  SettingsNotifier get _controller => ref.read(settingsProvider.notifier);
  String? _openGroup;
  AppSettings _s = AppSettings.defaults;
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
  // GPT-P1：zip 备份恢复——选好时读到的完整字节常驻内存，确认时
  // 直接用这份字节恢复，不再按路径重读（校验过的字节与导入的字节
  // 必须是同一份；磁盘上的文件被替换/删除也不影响。zip 可能很大，
  // 但解析时已读过一次、确认弹窗是模态短时持有，内存代价可接受。
  // 老 JSON 备份沿用 _restoreData，zipBytes 为 null）。
  List<int>? _restoreZipBytes;

  // 空间占用与孤儿清理：只在打开数据组时扫描一次。
  ({int importsBytes, int slicesBytes})? _storageUsage;
  OrphanScan? _orphanScan;

  // 迁移进度：搬库进行中显示百分比，可取消。
  bool _migrating = false;
  double _migrateProgress = 0;
  bool _migrateCancelled = false;

  // 缓存清理：只在打开数据组时扫描一次；清理完显示释放量，可重新扫描。
  CachePreview? _cachePreview;
  bool _cacheScanned = false;
  String? _cacheCleanedMb;

  // B11-9 考试倒计时：考试事件列表（独立数据，与试卷无任何关联）。
  List<ExamEvent> _examEvents = const [];
  final _examNameController = TextEditingController();
  DateTime? _newExamDate;

  // M6：BigModel key（OCR 服务凭据，见 _buildData 末尾）。
  // key 只进安全存储：本页只调 OcrKeyStore 的 set/has/clear，
  // 绝不读出 key 值（不调用 getApiKey）、不显示、不记日志。
  // 输入框平时为空，保存后立即清空，不让 key 滞留在控制器里。
  late final OcrKeyStore _keyStore;
  final _apiKeyController = TextEditingController();
  bool? _keySet; // null = 还没读过（数据组没打开过）；true/false = 已设置/未设置
  bool _keyBusy = false;

  @override
  void initState() {
    super.initState();
    _keyStore = widget.keyStore ?? OcrKeyStore();
    _greetingController.text = _s.greeting;
    // B11-9：从首页倒计时点进来时直接展开考试组（平时为 null，全折）。
    _openGroup = widget.initialOpenGroup;
    _loadQuestionCount();
    // M6：直接展开数据组时同样读一次 key 状态。
    if (_openGroup == 'data') _loadKeyStatus();
    // B11-9：考试列表平时不读——只在考试组打开时才读（见 _toggleGroup），
    // 这样不打开考试组的用例（包括只 pump 设置页的旧测试）完全不受影响。
    // 从首页倒计时点进来时组已展开，这里直接读一次。
    if (_openGroup == 'exams') _loadExamEvents();
  }

  Future<void> _loadExamEvents() async {
    try {
      final list = await _controller.loadExamEvents();
      if (!mounted) return;
      setState(() => _examEvents = list);
    } catch (_) {
      // 考试列表读不到不影响设置页本身；只显示空态。
    }
  }

  Future<void> _loadQuestionCount() async {
    try {
      final count = await _controller.loadQuestionCount();
      if (!mounted) return;
      setState(() => _questionCount = count);
    } catch (_) {
      // 计数拿不到不影响设置页本身；恢复确认里只写备份题数。
    }
  }

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // B11-9：应用层换了 initialOpenGroup（如从首页倒计时点进来）
    // 时跟进展开对应组；用户自己在页内折叠/展开后不再干预。
    if (widget.initialOpenGroup != oldWidget.initialOpenGroup &&
        widget.initialOpenGroup != null) {
      _openGroup = widget.initialOpenGroup;
    }
  }

  @override
  void dispose() {
    _greetingController.dispose();
    _examNameController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  /// 保存一组设置：唯一保存路径——经 settingsProvider 写库，
  /// 写成功后 Provider 重建本页（build 里把新值同步进 _s），
  /// 这里不再 setState（Stage 0 的 onSettingsChanged 已合并进来）。
  Future<void> _apply(AppSettings s) async {
    await ref.read(settingsProvider.notifier).saveSettings(s);
  }

  void _toggleGroup(String key) {
    setState(() {
      _openGroup = _openGroup == key ? null : key;
      if (_openGroup == 'data' && !_cacheScanned) _scanCache();
      if (_openGroup == 'data') _scanStorageAndOrphans();
      // M6：打开数据组时读一次 key 状态（只读 hasApiKey，不读 key 本身）。
      if (_openGroup == 'data') _loadKeyStatus();
      // B11-9：考试组打开时才读考试列表（平时不读，见 initState 注释）。
      if (_openGroup == 'exams') _loadExamEvents();
    });
  }

  // ---------- 数据：BigModel key（M6，OCR 服务凭据） ----------

  /// 只读“有没有 key”，绝不读出 key 值。读不到时状态保持上次的值，
  /// 设置页本身不受影响。
  Future<void> _loadKeyStatus() async {
    try {
      final has = await _keyStore.hasApiKey();
      if (!mounted) return;
      setState(() => _keySet = has);
    } catch (_) {}
  }

  /// 保存 key：空串按 OcrKeyStore 契约视为清除。保存后立即清空
  /// 输入框（key 不滞留）；存入了非空 key 才唤醒 worker——排队的
  /// OCR 任务不用等满 10 分钟才跑（worker 没启动时是空操作）。
  /// 十三批 P1-1（GPT §3.3）：唤醒前先清掉“等 key”的 available_at，
  /// 否则只是唤醒循环、任务仍被 10 分钟延迟挡住。
  Future<void> _saveApiKey() async {
    if (_keyBusy) return;
    final text = _apiKeyController.text;
    setState(() => _keyBusy = true);
    try {
      await _keyStore.setApiKey(text);
      if (text.trim().isNotEmpty) {
        await OcrWorker.instanceOrNull?.notifyApiKeySaved();
      }
      _apiKeyController.clear();
      await _loadKeyStatus();
      _snack(text.trim().isEmpty ? 'BigModel key 已清除' : 'BigModel key 已保存');
    } catch (_) {
      _snack('没保存上，稍后再试');
    } finally {
      if (mounted) setState(() => _keyBusy = false);
    }
  }

  /// 清除 key（输入框内容不动，只清已存的 key；输入框本身保存后
  /// 已是空的，平时也不预填 key）。
  Future<void> _clearApiKey() async {
    if (_keyBusy) return;
    setState(() => _keyBusy = true);
    try {
      await _keyStore.clearApiKey();
      _apiKeyController.clear();
      await _loadKeyStatus();
      _snack('BigModel key 已清除');
    } catch (_) {
      _snack('没清除掉，稍后再试');
    } finally {
      if (mounted) setState(() => _keyBusy = false);
    }
  }

  /// P3 §4.5/§6 第 9 条：打开数据组时统计空间占用、扫描孤儿文件。
  /// 孤儿清理的提醒就放在这里：每次打开数据组，有孤儿就提示一次。
  Future<void> _scanStorageAndOrphans() async {
    try {
      final usage = await _controller.storageUsage();
      if (!mounted) return;
      setState(() => _storageUsage = usage);
    } catch (_) {}
    try {
      final scan = await _controller.scanOrphans();
      if (!mounted) return;
      setState(() => _orphanScan = scan);
    } catch (_) {}
  }

  /// B3：孤儿清理确认改模态弹窗（文案与原来行内条一致）。
  Future<void> _askOrphanCleanup() async {
    final scan = _orphanScan;
    if (scan == null || scan.files.isEmpty) return;
    final ok = await _showConfirmDialog(
      title: '清理无用文件，确定吗？',
      detail:
          '将把 ${scan.count} 个没人用的文件（共约 ${ImportService.formatBytes(scan.totalBytes)}）移入回收站，题目和数据不动，7 天后彻底删除。确定清理吗？',
      confirmLabel: '确认清理',
    );
    if (ok && mounted) await _clearOrphans();
  }

  /// P3 §4.5：孤儿清理——确认后执行，只移预览里列出的无引用文件
  /// （WP-C #8 U3-2：移入回收站，物理删除只在启动清扫时执行）。
  Future<void> _clearOrphans() async {
    final scan = _orphanScan;
    if (scan == null || scan.files.isEmpty) return;
    try {
      final result = await _controller.clearOrphans(
        scan.files.map((f) => f.relativePath).toList(),
      );
      if (!mounted) return;
      setState(() => _orphanScan = null);
      await _scanStorageAndOrphans();
      _snack(
        result.deletedCount == 0
            ? '没有可清理的无用文件'
            : '已把 ${result.deletedCount} 个无用文件移入回收站，7 天后彻底删除',
      );
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
    AppSettings next;
    try {
      next = _controller.greetingToSave(_s, _greetingController.text);
    } on SettingsValidationException catch (e) {
      _snack(e.message);
      return;
    }
    await _apply(next);
    _snack('问候语已保存');
  }

  Future<void> _resetGreeting() async {
    _greetingController.text = SettingsNotifier.defaultGreetingText;
    await _apply(_controller.defaultGreeting(_s));
  }

  // ---------- 数据：备份 / 恢复 ----------

  /// 待定3：记一次备份失败——写库标志 + 通知应用层点亮首页横幅。
  /// 标志写失败也不影响本页的即时提示（静默跳过）。
  Future<void> _markBackupFailed() async {
    try {
      await _controller.markBackupFailed();
    } catch (_) {}
    widget.onBackupFailed?.call();
  }

  Future<void> _backup() async {
    setState(() => _busy = true);
    try {
      // P3 §2.3：备份改为 zip（JSON + imports/ + slices/），扩展名
      // 仍是 .qm2backup，内容改为 zip；恢复即完整（含题目图片）。
      // 十四批 M2：带警告的导出——派生文件缺失/不可读与图块损坏
      // 只警告、不阻断；十四批 M5 修复轮 3（D-155）：库行直接引用
      // 的资产缺失/不可读时备份直接失败（BackupRestoreException，
      // 文案里指明题目/任务 ID 与相对路径）。
      final report = await _controller.exportBackupBytesWithReport();
      final bytes = report.bytes;
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
          await _controller.clearBackupFailedFlag();
        } catch (_) {}
        _snack(
          // WP-C #8 U3-2：部分完成的备份必须明示，不静默记“已保存”。
          report.status == BackupExportStatus.complete
              ? '备份已保存（含题目图片，此备份仅新版可恢复）'
              : '备份已保存（部分完成：${report.brokenFiles.length} 个文件未包含在备份中；${report.warnings.join('；')}）',
        );
      } catch (_) {
        // 待定3：写文件失败 = 本次备份失败，记标志（首页出红横幅）；
        // 本页原有的即时提示保留。
        await _markBackupFailed();
        _snack('备份没存上，换个位置再试一次');
      }
    } on BackupRestoreException catch (e) {
      // 导出失败且原因明确（如直接引用的资产缺失，D-155）：把原因
      // 原文提示给用户（里面含题目/任务 ID 与相对路径），同时记一次
      // 备份失败。
      await _markBackupFailed();
      _snack(e.message);
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
    // GPT-P1：恢复直接用选好时读到的字节，不再按路径重读、也不再
    // 做指纹重查——校验过的字节与导入的字节是同一份，磁盘上的文件
    // 在选好后被替换/删除不影响本次恢复。
    final zipBytes = _restoreZipBytes;
    setState(() {
      _busy = true;
      _restoreData = null;
      _restoreFileName = null;
      _restoreZipBytes = null;
    });
    try {
      // D-173：恢复前先看有没有未完成复习会话——恢复会清掉它
      // （十四批 M2 P1-6），文案只在真清掉时才提；没有会话时只说
      // 恢复成功。恢复前查：恢复事务里 review_state 已被清掉。
      final hadUnfinishedSession =
          await _controller.hasUnfinishedReviewSession();
      // 十四批 M2：恢复返回警告列表（缺失/不可读的图块已从引用里去掉）。
      final warnings = await _controller.restoreBackup(
        jsonData: data,
        zipBytes: zipBytes,
      );
      // 恢复成功已发一个含全部五种 kind 的变更事件（见
      // AppDatabase.importBackupJson/Zip），角标由 badgeCountsProvider
      // 刷新，本页不再手动 bump。
      // 恢复可能覆盖了设置表：从库里重读一次，Provider 更新后
      // 根组件与本页同时看到恢复后的设置（Stage 0 是 loadSettings
      // + _apply 两步，现合并为一次 reloadSettings）。
      await _controller.reloadSettings();
      await _loadQuestionCount();
      // FR-06(b)：恢复会改写库与文件，恢复前的孤儿扫描已过期——
      // 置空并重扫，否则旧列表里“恢复后重新被引用”的文件会在下次
      // 清理时被误删（(a) 的删除前重算是第二道防线）。
      if (mounted) setState(() => _orphanScan = null);
      await _scanStorageAndOrphans();
      // D-173：恢复成功文案按恢复前有没有未完成会话分支（见文件顶
      // `restoreSuccessMessage`）；图块警告有则追加。
      _snack(
        restoreSuccessMessage(
          hadUnfinishedSession: hadUnfinishedSession,
          warnings: warnings,
        ),
      );
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

  /// B3：恢复确认改模态弹窗（文案与原来行内条一致；恢复是覆盖不是
  /// 删除，但共用同一行内确认条，按“行内确认条全部改掉”一并改）。
  /// 选完文件即弹确认；取消则丢弃刚选的文件（与原来行内条的取消一致）。
  Future<void> _askRestore() async {
    final data = _restoreData;
    if (data == null) return;
    final pendingQuestions = (data['questions'] as List?)?.length ?? 0;
    final ok = await _showConfirmDialog(
      title: '恢复会覆盖当前题库，确定吗？',
      detail:
          '将用备份文件「${_restoreFileName ?? '备份文件'}」（$pendingQuestions 道题）覆盖现在的题库（当前 $_questionCount 道题）：现在的题会被替换掉，覆盖后找不回来。确定恢复吗？',
      confirmLabel: '确认恢复，覆盖当前题库',
    );
    if (!ok) {
      setState(() {
        _restoreData = null;
        _restoreFileName = null;
        _restoreZipBytes = null;
      });
      return;
    }
    await _confirmRestore();
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
    // P3 §2.3：按魔数识别，不靠扩展名——新 zip 备份以 PK 开头，
    // 老 .qm2backup JSON 内容是 JSON 文本；两者恢复口径不同，
    // 不要静默读坏。解析在 Controller，页面只按异常类型提示。
    ({Map<String, dynamic> data, List<int>? zipBytes}) parsed;
    try {
      parsed = await _controller.parseRestoreFile(path);
    } on RestoreFileReadException {
      _snack('这个备份文件打不开，换一个再试');
      return;
    } on BackupRestoreException catch (e) {
      _snack(e.message);
      return;
    } catch (_) {
      _snack('这个文件不是 quiz-master2 的备份，恢复不了');
      return;
    }
    setState(() {
      _restoreFileName = result!.files.single.name;
      _restoreData = parsed.data;
      _restoreZipBytes = parsed.zipBytes;
    });
    await _askRestore();
  }

  String get _dbPath => _controller.dbPath;

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
    if (_controller.databaseExistsAt(dir)) {
      final choice = await showDialog<String>(
        context: context,
        builder: (dctx) => AlertDialog(
          title: const Text('这个位置已经有题库了'),
          content: const Text(
            '新位置已经有一个 quiz-master2.db。覆盖会用现在的题库替换它（题库和图片一起搬过去；新位置原来的题库就没了）；保留会直接用新位置原来的题库，现在的题库留在原位置不动。',
          ),
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
        await _controller.keepExistingDatabase(dir);
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
    final outcome = await _controller.migrateDatabase(
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

  void _scanCache() {
    setState(() {
      _cachePreview = _controller.scanCache();
      _cacheScanned = true;
      _cacheCleanedMb = null;
    });
  }

  Future<void> _clearCache() async {
    final preview = _cachePreview;
    if (preview == null) return;
    final deleted = await _controller.clearCache(preview);
    setState(() {
      _cacheCleanedMb = preview.mb;
      _cachePreview = _controller.scanCache();
    });
    _snack(deleted == 0 ? '没有可清理的缓存' : '已清理 $deleted 项缓存');
  }

  Future<void> _pickNotifyTime() async {
    final parts = _s.notifyTime.split(':');
    final initial = TimeOfDay(
      hour: int.tryParse(parts.elementAtOrNull(0) ?? '') ?? 20,
      minute: int.tryParse(parts.elementAtOrNull(1) ?? '') ?? 0,
    );
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null) return;
    final text =
        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    await _apply(_s.copyWith(notifyTime: text));
  }

  // ---------- 考试倒计时（B11-9） ----------

  /// 新增一场考试：只填自定义名称 + 考试日期，不选试卷、不关联试卷。
  Future<void> _addExamEvent() async {
    try {
      await _controller.addExamEvent(
        existing: _examEvents,
        name: _examNameController.text,
        date: _newExamDate,
      );
    } on SettingsValidationException catch (e) {
      _snack(e.message);
      return;
    } catch (_) {
      _snack('没加上，稍后再试');
      return;
    }
    _examNameController.clear();
    setState(() => _newExamDate = null);
    await _loadExamEvents();
  }

  Future<void> _pickNewExamDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _newExamDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() => _newExamDate = dateOnly(picked));
  }

  /// 改名：弹窗里改，保存后原地更新（顺序仍按日期排）。
  /// 用 TextFormField(initialValue + onChanged)，不用
  /// TextEditingController：弹窗关闭动画期间字段仍挂在树上，
  /// 这时 dispose 控制器会触发“used after being disposed”。
  Future<void> _renameExamEvent(ExamEvent e) async {
    var name = e.name;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('改考试名称'),
        content: TextFormField(
          key: const Key('exam-rename-field'),
          initialValue: e.name,
          maxLength: 40,
          autofocus: true,
          decoration: const InputDecoration(hintText: '考试名称'),
          onChanged: (v) => name = v,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    name = name.trim();
    if (ok != true || name.isEmpty || name == e.name) return;
    try {
      await _controller.renameExamEvent(
        event: e,
        newName: name,
        existing: _examEvents,
      );
    } on SettingsValidationException catch (err) {
      _snack(err.message);
      return;
    } catch (_) {
      _snack('没改成，稍后再试');
      return;
    }
    await _loadExamEvents();
  }

  /// 改日期：弹窗选日期，保存后原地更新。
  Future<void> _pickExamEventDate(ExamEvent e) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: e.date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    final date = dateOnly(picked);
    if (date == e.date) return;
    try {
      await _controller.changeExamEventDate(e, date);
    } catch (_) {
      _snack('没改成，稍后再试');
      return;
    }
    await _loadExamEvents();
  }

  /// 删除一场考试：只删事件本身，不动任何题目/试卷。
  Future<void> _deleteExamEvent(ExamEvent e) async {
    final ok = await _showConfirmDialog(
      title: '删除这场考试，确定吗？',
      detail: '「${e.name}」删了就没了，确定吗？',
      confirmLabel: '删除',
    );
    if (!ok) return;
    try {
      await _controller.deleteExamEvent(e.id);
    } catch (_) {
      _snack('没删掉，稍后再试');
      return;
    }
    await _loadExamEvents();
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    // 业务设置只从 settingsProvider 读：加载中先转圈（生产上根组件
    // 已等 Provider 就绪才进本页，这里只覆盖单测直 pump 本页的情形）；
    // 读到新值时同步进本地镜像 _s（问候语输入框文本同时跟进，
    // 文本相同时不重复赋值，避免打断正在输入的光标）。
    final settingsAsync = ref.watch(settingsProvider);
    final latest = settingsAsync.value;
    if (latest == null) {
      if (settingsAsync.isLoading) {
        return const Center(child: CircularProgressIndicator());
      }
      // 读设置出错且无旧值：用默认设置继续跑（错误横幅由
      // widget.loadFailed 控制，与原来一致）。
    }
    if (latest != null && latest.toMap().toString() != _s.toMap().toString()) {
      _s = latest;
      if (_greetingController.text != latest.greeting) {
        _greetingController.text = latest.greeting;
      }
    }
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
            title: '考试',
            expanded: _openGroup == 'exams',
            onToggle: () => _toggleGroup('exams'),
            child: _buildExams(),
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

  /// B3：删除/覆盖类确认统一用模态 AlertDialog（原来是行内确认条）。
  /// 只统一形式，标题/后果文案/确认按钮文案沿用原字句。
  Future<bool> _showConfirmDialog({
    required String title,
    required String detail,
    required String confirmLabel,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(title),
        content: Text(detail),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// 设置行：标题 + 一行短说明 + 右侧控件；窄屏时控件换到下一行。
  Widget _row(String title, String desc, Widget control) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final text = Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: R10Tokens.settingsRowTitleFontSize,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: 2 * scale),
          Text(
            desc,
            style: TextStyle(
              fontSize: R10Tokens.settingsRowDescFontSize,
              color: palette.muted,
            ),
          ),
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
    return QmSegmented<T>(options: options, value: value, onChanged: onChanged);
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
        _row('加入方式', '手动加入：在题目详情点「加入复习」。', const SizedBox.shrink()),
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
              QmSegmentOption(value: 'subj-asc', label: '学科首字母 A → Z'),
              QmSegmentOption(value: 'subj-desc', label: '学科首字母 Z → A'),
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

  /// B11-9 考试倒计时：考试管理。只填自定义名称 + 考试日期，
  /// 不选试卷、不关联试卷；首页只显示最近一场考试的倒计时。
  Widget _buildExams() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _noteText('这里的考试只用来在首页倒计时，不关联任何试卷。'),
        SizedBox(height: 8 * scale),
        _row(
          '加一场考试',
          '填个名字、选个日期，首页就会显示倒计时。',
          SizedBox(
            width: 460 * scale,
            child: Row(
              children: [
                Expanded(
                  child: QmTextField(
                    key: const Key('exam-name-field'),
                    controller: _examNameController,
                    hintText: '考试名称，如期末考试',
                    maxLength: 40,
                    onSubmitted: (_) => _addExamEvent(),
                  ),
                ),
                SizedBox(width: 8 * scale),
                QmButton(
                  key: const Key('exam-date-button'),
                  label: _newExamDate == null
                      ? '选日期'
                      : formatExamEventDate(_newExamDate!),
                  variant: QmButtonVariant.secondary,
                  size: QmButtonSize.small,
                  onPressed: _pickNewExamDate,
                ),
                SizedBox(width: 8 * scale),
                QmButton(
                  key: const Key('exam-add-button'),
                  label: '添加考试',
                  size: QmButtonSize.small,
                  onPressed: _addExamEvent,
                ),
              ],
            ),
          ),
        ),
        if (_examEvents.isEmpty)
          _noteText('还没有考试，加一场吧。')
        else
          for (final e in _examEvents)
            Padding(
              key: Key('exam-event-row-${e.id}'),
              padding: EdgeInsets.symmetric(vertical: 8 * scale),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          e.name,
                          style: const TextStyle(
                            fontSize: R10Tokens.settingsRowTitleFontSize,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 2 * scale),
                        Text(
                          '${formatExamEventDate(e.date)} · '
                          '${examCountdownText(e)}',
                          style: TextStyle(
                            fontSize: R10Tokens.settingsRowDescFontSize,
                            color: palette.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: 16 * scale),
                  QmButton(
                    key: Key('exam-rename-${e.id}'),
                    label: '改名',
                    variant: QmButtonVariant.plain,
                    size: QmButtonSize.small,
                    onPressed: () => _renameExamEvent(e),
                  ),
                  SizedBox(width: 8 * scale),
                  QmButton(
                    key: Key('exam-change-date-${e.id}'),
                    label: '改日期',
                    variant: QmButtonVariant.plain,
                    size: QmButtonSize.small,
                    onPressed: () => _pickExamEventDate(e),
                  ),
                  SizedBox(width: 8 * scale),
                  QmButton(
                    key: Key('exam-delete-${e.id}'),
                    label: '删除',
                    variant: QmButtonVariant.plain,
                    size: QmButtonSize.small,
                    onPressed: () => _deleteExamEvent(e),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  Widget _buildData() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final preview = _cachePreview;
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
          _noteText(
            _dbMigrated
                ? '新位置已保存：题库已迁过去，重启后彻底生效。'
                : '新位置已保存：要重启软件才生效——重启后才会改用新位置存数据库，重启前还是用现在这个位置。',
          ),
        if (_migrating)
          _noteText(
            '正在迁移…${(_migrateProgress * 100).toStringAsFixed(0)}%（题库和图片一起搬，搬完前不要退出）。',
          ),
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
                : () => _askOrphanCleanup(),
          ),
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
          _noteText(
            preview.failedCount > 0
                ? '其中含导入失败的残留文件 ${preview.failedCount} 个，缩略图之后用到时会自动重新生成。'
                : '缩略图之后用到时会自动重新生成。',
          ),
        // M6：BigModel key（OCR 服务凭据）。放数据组：它是 OCR 服务的
        // 凭据，与备份/数据库位置同属“数据”范畴；其他组（外观/复习/
        // 错题本/考试/启动与关于）都不贴切。输入框密码式遮蔽，平时
        // 为空、从不预填 key；状态只显示已设置/未设置，key 值本身
        // 永不显示（本页不调用 getApiKey）。
        _row(
          'BigModel key',
          'OCR 识别用的 BigModel API Key，只存在本机安全存储，不进题库、不进备份。保存后排队的识别任务会立即开始，不用等。',
          SizedBox(
            width: 460 * scale,
            child: Row(
              children: [
                Expanded(
                  child: QmTextField(
                    key: const Key('bigmodel-key-field'),
                    controller: _apiKeyController,
                    hintText: '粘贴 BigModel API Key',
                    obscureText: true,
                    enabled: !_keyBusy,
                    onSubmitted: (_) => _saveApiKey(),
                  ),
                ),
                SizedBox(width: 8 * scale),
                QmButton(
                  key: const Key('bigmodel-key-save'),
                  label: '保存',
                  size: QmButtonSize.small,
                  onPressed: _keyBusy ? null : _saveApiKey,
                ),
                SizedBox(width: 8 * scale),
                QmButton(
                  key: const Key('bigmodel-key-clear'),
                  label: '清除',
                  variant: QmButtonVariant.plain,
                  size: QmButtonSize.small,
                  onPressed: _keyBusy ? null : _clearApiKey,
                ),
              ],
            ),
          ),
        ),
        Text(
          _keySet == null
              ? '状态：读取中…'
              : _keySet!
              ? '状态：已设置'
              : '状态：未设置',
          key: const Key('bigmodel-key-status'),
          style: TextStyle(
            fontSize: R10Tokens.settingsRowDescFontSize,
            color: palette.muted,
          ),
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
            child: Text(
              label,
              style: TextStyle(
                fontSize: R10Tokens.kvFontSize,
                fontWeight: FontWeight.w700,
                color: palette.ink,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: R10Tokens.kvFontSize,
                color: palette.ink2,
              ),
            ),
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
        _row('关于', '版本与更新说明。', const SizedBox.shrink()),
        _kvRow('版本', 'quiz-master2 v0.1.0'),
        _kvRow('作者', 'Meng（个人项目）'),
        _kvRow(
          '更新说明',
          'v0.1.0：首个版本。错题收集 → 整理 → 按错因复习的主流程；学科管理定稿：学科 / 知识点树 / 标签 / 试卷可增删改，删学科删题，改名同步到题；文件夹只在错题本目录页管，删知识点 / 标签 / 试卷只让题上对应项变空（待补充）；主题默认跟随系统、可手动选亮 / 深，字体标准 / 大 / 特大三档；错题本目录页可增删改查文件夹，题可单个 / 批量移入其他文件夹。',
        ),
      ],
    );
  }
}
