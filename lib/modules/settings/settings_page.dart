import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../data/badge_notifier.dart';
import '../../data/database.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../theme/app_theme.dart';

/// 设置：分段折叠式五组（外观 / 复习 / 错题本 / 数据 / 启动与关于），
/// 默认全折起，一次只展开一个。每项标题 + 一句短说明 + 选项，简洁直接。
/// 改设置后调 onSettingsChanged 保存并刷新主题 / 字体。
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.repo,
    required this.settings,
    required this.onSettingsChanged,
  });

  final QuestionRepository repo;
  final AppSettings settings;
  final Future<void> Function(AppSettings s) onSettingsChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String? _openGroup;
  late AppSettings _s;
  final _greetingController = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _s = widget.settings;
    _greetingController.text = _s.greeting;
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
    setState(() => _openGroup = _openGroup == key ? null : key);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirm(String title, String message,
      {String confirmLabel = '确定'}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  // ---------- 数据 ----------

  Future<void> _backup() async {
    setState(() => _busy = true);
    try {
      final json = await widget.repo.exportBackupJson();
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '备份题库',
        fileName: 'quiz-master2-backup.json',
        bytes: utf8.encode(json),
      );
      if (path != null) _snack('备份已保存');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static const _backupTables = [
    'subjects',
    'questions',
    'folders',
    'tags',
    'exams',
    'knowledge_points',
    'cause_records',
    'settings',
  ];

  Future<void> _restore() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '选择备份文件',
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    final bytes = result?.files.single.bytes;
    if (bytes == null) return;
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      data = decoded;
      if (data['questions'] is! List || data['subjects'] is! List) {
        throw const FormatException();
      }
    } catch (_) {
      _snack('这个文件不是 quiz-master2 的备份，恢复不了');
      return;
    }
    final ok = await _confirm('恢复备份', '恢复会覆盖当前题库，确定吗？',
        confirmLabel: '恢复');
    if (!ok) return;
    setState(() => _busy = true);
    try {
      final db = await widget.repo.db.db;
      await db.transaction((txn) async {
        for (final t in [
          'cause_records',
          'review_state',
          'review_history',
          'recent_tasks',
          'questions',
          'folders',
          'tags',
          'exams',
          'knowledge_points',
          'subjects',
          'settings',
        ]) {
          await txn.delete(t);
        }
        for (final t in _backupTables) {
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
      });
      bumpBadgeVersion();
      final restored = await widget.repo.settings();
      await _apply(restored);
      _snack('已恢复备份');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _dbPath {
    final used = widget.repo.db.dbPathUsed;
    if (used != null && used.isNotEmpty) return used;
    return '${AppDatabase.dataDirectoryPath()}${Platform.pathSeparator}quiz-master2.db';
  }

  Future<void> _changeDbLocation() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择数据库位置',
    );
    if (dir == null) return;
    await widget.repo.setCustomDataDirectory(dir);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('已保存新位置'),
        content: Text('新位置：$dir\n重启后生效。'),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 缓存清理预览：临时文件 + 缩略图缓存 + 失败导入残留，不动题目数据。
  List<FileSystemEntity> _cacheCandidates() {
    final dir = Directory(AppDatabase.dataDirectoryPath());
    if (!dir.existsSync()) return const [];
    final out = <FileSystemEntity>[];
    for (final e in dir.listSync()) {
      final name = e.path.split(Platform.pathSeparator).last;
      if (name == 'quiz-master2.db') continue;
      final lower = name.toLowerCase();
      if (e is Directory &&
          (lower.contains('cache') ||
              lower.contains('thumb') ||
              lower.contains('tmp'))) {
        out.add(e);
      } else if (e is File &&
          (lower.endsWith('.tmp') ||
              lower.endsWith('.cache') ||
              lower.startsWith('thumb'))) {
        out.add(e);
      }
    }
    return out;
  }

  Future<void> _clearCache() async {
    final candidates = _cacheCandidates();
    final ok = await _confirm(
      '清理缓存',
      candidates.isEmpty
          ? '没有可清理的缓存。只清理临时文件、缩略图缓存和失败导入残留，不动题目数据。'
          : '将清理 ${candidates.length} 项（临时文件、缩略图缓存、失败导入残留），不动题目数据。确定吗？',
    );
    if (!ok) return;
    var deleted = 0;
    for (final e in candidates) {
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
    _snack(deleted == 0 ? '没有可清理的缓存' : '已清理 $deleted 项缓存');
  }

  Future<void> _clearDemo() async {
    final count = await widget.repo.demoQuestionCount();
    if (count == 0) {
      _snack('没有演示数据');
      return;
    }
    final ok = await _confirm('清空演示数据', '会删掉 $count 道演示题，确定吗？');
    if (!ok) return;
    final n = await widget.repo.clearDemoData();
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
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('设置', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 16),
          _group(key: 'appearance', title: '外观', child: _buildAppearance()),
          _group(key: 'review', title: '复习', child: _buildReview()),
          _group(key: 'wrongbook', title: '错题本', child: _buildWrongbook()),
          _group(key: 'data', title: '数据', child: _buildData()),
          _group(key: 'startup', title: '启动与关于', child: _buildStartup()),
        ],
      ),
    );
  }

  Widget _group(
      {required String key, required String title, required Widget child}) {
    final open = _openGroup == key;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => _toggleGroup(key),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  Icon(open
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down),
                ],
              ),
            ),
          ),
          if (open) ...[
            const Divider(height: 1),
            const SizedBox(height: 8),
            child,
          ],
        ],
      ),
    );
  }

  Widget _row(String title, String desc, Widget control) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(desc, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 16),
          control,
        ],
      ),
    );
  }

  Widget _segmented<T>({
    required T value,
    required List<({T value, String label})> options,
    required ValueChanged<T> onChanged,
  }) {
    return SegmentedButton<T>(
      segments: [
        for (final o in options)
          ButtonSegment(value: o.value, label: Text(o.label)),
      ],
      selected: {value},
      onSelectionChanged: (v) => onChanged(v.first),
    );
  }

  Widget _buildAppearance() {
    return Column(
      children: [
        _row(
          '主题',
          '跟随系统，或手动选浅色 / 深色。',
          _segmented<String>(
            value: _s.themeMode,
            options: const [
              (value: 'system', label: '跟随系统'),
              (value: 'light', label: '浅色'),
              (value: 'dark', label: '深色'),
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
              (value: 'standard', label: '标准'),
              (value: 'large', label: '大'),
              (value: 'extraLarge', label: '特大'),
            ],
            onChanged: (v) => _apply(_s.copyWith(fontSize: v)),
          ),
        ),
        _row(
          '首页问候语',
          '首页顶部显示的一句话。',
          SizedBox(
            width: 280,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _greetingController,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (v) {
                      final text =
                          v.trim().isEmpty ? '今天也要加油呀' : v.trim();
                      _apply(_s.copyWith(greeting: text));
                    },
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    _greetingController.text = '今天也要加油呀';
                    _apply(_s.copyWith(greeting: '今天也要加油呀'));
                  },
                  child: const Text('恢复默认'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildReview() {
    return Column(
      children: [
        _row(
          '复查间隔',
          '错因解决后，几天后回来复查。',
          _segmented<int>(
            value: _s.recheckIntervalDays,
            options: const [
              (value: 3, label: '3 天'),
              (value: 7, label: '7 天'),
              (value: 14, label: '14 天'),
            ],
            onChanged: (v) => _apply(_s.copyWith(recheckIntervalDays: v)),
          ),
        ),
        _row(
          '几次自查算已解决',
          '同一错因在同一道题上自查“已解决”几次才算解决。',
          _segmented<int>(
            value: _s.cureChecks,
            options: const [
              (value: 1, label: '1 次'),
              (value: 2, label: '2 次'),
              (value: 3, label: '3 次'),
            ],
            onChanged: (v) => _apply(_s.copyWith(cureChecks: v)),
          ),
        ),
        _row(
          '每次复习解决几个错因',
          '到数量后出本轮复习总结。',
          _segmented<int>(
            value: _s.causesPerSession,
            options: const [
              (value: 5, label: '5 个'),
              (value: 10, label: '10 个'),
              (value: 0, label: '不限'),
            ],
            onChanged: (v) => _apply(_s.copyWith(causesPerSession: v)),
          ),
        ),
        _row(
          '跳过几次留到下次',
          '第一次跳过移到队尾，再跳过就留到下次。',
          _segmented<int>(
            value: _s.skipLimit,
            options: const [
              (value: 1, label: '1 次'),
              (value: 2, label: '2 次'),
            ],
            onChanged: (v) => _apply(_s.copyWith(skipLimit: v)),
          ),
        ),
        _row(
          '重做时答案默认',
          '重做那步，答案先藏着还是直接显示。',
          _segmented<bool>(
            value: !_s.redoAnswerHidden,
            options: const [
              (value: false, label: '藏着'),
              (value: true, label: '显示'),
            ],
            onChanged: (v) => _apply(_s.copyWith(redoAnswerHidden: !v)),
          ),
        ),
        _row(
          '通知提醒',
          '到复查时间时提醒你。',
          Switch(
            value: _s.notifyEnabled,
            onChanged: (v) => _apply(_s.copyWith(notifyEnabled: v)),
          ),
        ),
        _row(
          '提醒时间',
          '每天在这个时间提醒。',
          OutlinedButton(
            onPressed: _s.notifyEnabled ? _pickNotifyTime : null,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.accent,
              side: const BorderSide(color: AppTheme.accent),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(_s.notifyTime),
          ),
        ),
        _row(
          '复习列表默认排序',
          '打开复习页时先按什么排。',
          _segmented<String>(
            value: _s.reviewSort,
            options: const [
              (value: 'joinTime', label: '按加入时间'),
              (value: 'subject', label: '按学科'),
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
              (value: 'large', label: '大卡片'),
              (value: 'compact', label: '紧凑列表'),
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
              (value: 'new', label: '时间新 → 旧'),
              (value: 'old', label: '时间旧 → 新'),
              (value: 'subject', label: '学科首字母'),
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
              (value: 10, label: '10'),
              (value: 20, label: '20'),
              (value: 30, label: '30'),
              (value: 40, label: '40'),
              (value: 50, label: '50'),
            ],
            onChanged: (v) => _apply(_s.copyWith(pageSize: v)),
          ),
        ),
      ],
    );
  }

  Widget _buildData() {
    return Column(
      children: [
        _row(
          '备份',
          '把题库导出为一个 JSON 文件。',
          FilledButton(
            onPressed: _busy ? null : _backup,
            child: const Text('备份'),
          ),
        ),
        _row(
          '恢复',
          '从备份文件恢复，会覆盖当前题库。',
          FilledButton(
            onPressed: _busy ? null : _restore,
            child: const Text('恢复'),
          ),
        ),
        _row(
          '数据库位置',
          '当前数据库文件的位置，改后重启才生效。',
          SizedBox(
            width: 300,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SelectableText(
                  _dbPath,
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.right,
                ),
                const SizedBox(height: 6),
                OutlinedButton(
                  onPressed: _changeDbLocation,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.accent,
                    side: const BorderSide(color: AppTheme.accent),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('更改位置'),
                ),
              ],
            ),
          ),
        ),
        _row(
          '缓存清理',
          '清理临时文件、缩略图缓存和失败导入残留，不动题目数据。',
          FilledButton(
            onPressed: _clearCache,
            child: const Text('清理缓存'),
          ),
        ),
        _row(
          '清空演示数据',
          '只删演示题，你自己的题不动。',
          FilledButton(
            onPressed: _clearDemo,
            child: const Text('清空演示数据'),
          ),
        ),
      ],
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
              (value: 'home', label: '首页'),
              (value: 'last', label: '上次停下的页面'),
            ],
            onChanged: (v) => _apply(_s.copyWith(startupPage: v)),
          ),
        ),
        _row(
          '关于',
          '版本 v0.1.0\n作者：Meng\nv0.1.0：全新 v2，第一版。',
          const SizedBox.shrink(),
        ),
      ],
    );
  }
}
