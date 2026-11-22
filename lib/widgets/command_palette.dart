// 十九批 A4：全局 Ctrl+K 命令面板（板子 §6.1）。
//
// 样式按板子：遮罩 rgba(15,23,42,.45)、面板最大宽 620px、圆角 14px、
// 输入框 17px、分组标题 12px #94A3B8、条目 14px（悬停/选中底
// #E1EDFF）、hint 计数右对齐 12px #94A3B8、列表区最大高 46vh、
// 底部快捷键栏「↑↓ 选择 / Enter 打开 / Esc 关闭 / 不搜题干文字」。
//
// 呼出：app.dart 的全局 HardwareKeyboard 监听（任意页面 Ctrl+K /
// Cmd+K）；不加页面右下角浮动按钮（板子注明是演示用）。
// 键盘：↑↓ 移动选中、Enter 应用、Esc/点遮罩关闭。方向键不能走
// TextField 上层的 CallbackShortcuts——文本框的默认快捷键会先
// 吞掉方向键（见 default_text_editing_shortcuts.dart），所以本
// 面板用 HardwareKeyboard.addHandler 在焦点派发之前拦截。
// 计数：各条目的 hint 取真实后端数据（见 _load 里
// countQuestionsForConditions，与点进去看到的结果数同一口径）。
// 选中后关面板、调 onApply（conditions + 显示名）；由调用方决定
// 是直接应用（错题本页内）还是先切到 /wrongbook 再应用（app 层）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/repository.dart';
import '../models/models.dart';
import '../state/wrongbook_notifier.dart';

/// 命令面板是否正打开（app 层 Ctrl+K 监听用：面板已开时不再叠开一层）。
class CommandPalette extends StatefulWidget {
  const CommandPalette({
    super.key,
    required this.repo,
    required this.onApply,
  });

  /// 面板打开时为 true（State 的 initState/dispose 维护）。
  static bool isOpen = false;

  final QuestionRepository repo;

  /// 选中一条后的回调（条件 + 显示名，如「洛必达法则」/「概念不清 · 未解决」）。
  final void Function(Map<String, dynamic> conditions, String label) onApply;

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _PaletteGroup {
  const _PaletteGroup({required this.title, required this.items});
  final String title;
  final List<_PaletteItem> items;
}

class _PaletteItem {
  const _PaletteItem({
    required this.icon,
    required this.name,
    required this.conditions,
    required this.hint,
  });

  /// 板子里的分组符号：★ / 📁 / ✕ / ◆ / ＃ / ▤（文字符号）。
  final String icon;

  /// 显示名（不含符号，如「洛必达法则」「概念不清 · 未解决」）。
  final String name;

  /// 点按后应用的查找条件（与 SavedSearch.conditions 同一形状）。
  final Map<String, dynamic> conditions;

  /// 右侧 hint，如「31 道」「数学 · 23 道」「试卷 · 26 道」。
  final String hint;

  String get label => '$icon $name';

  /// 过滤用：只按名字匹配（不含符号）。
  bool matches(String query) =>
      query.isEmpty || name.toLowerCase().contains(query.toLowerCase());
}

class _CommandPaletteState extends State<CommandPalette> {
  final _queryCtrl = TextEditingController();
  bool _loading = true;
  List<_PaletteGroup> _groups = const [];
  String _query = '';
  int _selected = 0;

  /// 当前可见（按输入过滤后）的条目，按分组顺序展平。
  List<_PaletteItem> get _visible {
    final out = <_PaletteItem>[];
    for (final g in _groups) {
      for (final item in g.items) {
        if (item.matches(_query)) out.add(item);
      }
    }
    return out;
  }

  /// 当前可见的分组（过滤后空分组不画标题）。
  List<_PaletteGroup> get _visibleGroups {
    final out = <_PaletteGroup>[];
    for (final g in _groups) {
      final items = g.items.where((i) => i.matches(_query)).toList();
      if (items.isNotEmpty) out.add(_PaletteGroup(title: g.title, items: items));
    }
    return out;
  }

  @override
  void initState() {
    super.initState();
    CommandPalette.isOpen = true;
    HardwareKeyboard.instance.addHandler(_handleKey);
    unawaited(_load());
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    CommandPalette.isOpen = false;
    _queryCtrl.dispose();
    super.dispose();
  }

  /// 焦点派发之前拦截：↑↓ 移动选中、Enter 应用、Esc 关闭。
  /// 可打印字符返回 false，放行给输入框。
  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      final n = _visible.length;
      if (n > 0) {
        setState(() {
          _selected = (_selected + 1).clamp(0, n - 1);
        });
      }
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      final n = _visible.length;
      if (n > 0) {
        setState(() {
          _selected = (_selected - 1).clamp(0, n - 1);
        });
      }
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      _applySelected();
      return true;
    }
    return false;
  }

  Future<void> _load() async {
    List<_PaletteGroup> groups = const [];
    try {
      final repo = widget.repo;
      final subjects = await repo.subjects();
      final questions = await repo.all(includeArchived: true);
      final folders = await repo.folders();
      final exams = await repo.exams();
      final tags = await repo.tags();
      final kps = await repo.knowledgePoints();
      final records = await repo.causeRecords();
      final saved = await repo.savedSearches();
      final byQ = <String, List<CauseRecord>>{};
      for (final r in records) {
        (byQ[r.questionId] ??= []).add(r);
      }
      String subjectName(String id) => subjects
          .where((s) => s.id == id)
          .map((s) => s.name)
          .firstOrNull ?? '';
      int count(Map<String, dynamic> conditions) =>
          countQuestionsForConditions(
            questions: questions,
            subjects: subjects,
            folders: folders,
            exams: exams,
            kps: kps,
            recordsByQ: byQ,
            conditions: conditions,
          );
      final built = <_PaletteGroup>[];
      if (saved.isNotEmpty) {
        built.add(
          _PaletteGroup(
            title: '我的查找',
            items: [
              for (final s in saved)
                _PaletteItem(
                  icon: '★',
                  name: s.name,
                  conditions: s.conditions,
                  hint: '${count(s.conditions)} 道',
                ),
            ],
          ),
        );
      }
      if (folders.isNotEmpty) {
        built.add(
          _PaletteGroup(
            title: '文件夹',
            items: [
              for (final f in folders)
                _PaletteItem(
                  icon: '📁',
                  name: f.name,
                  conditions: {'folderId': f.id, 'subjectId': f.subjectId},
                  hint:
                      '${subjectName(f.subjectId)} · ${count({'folderId': f.id, 'subjectId': f.subjectId})} 道',
                ),
            ],
          ),
        );
      }
      // 错因：固定枚举在前，现存题里的自定义错因在后（去重）。
      final causes = <String>{...ErrorTypes.fixed};
      for (final q in questions) {
        causes.addAll(q.allCauses);
      }
      if (causes.isNotEmpty) {
        built.add(
          _PaletteGroup(
            title: '错因',
            items: [
              for (final c in causes)
                _PaletteItem(
                  icon: '✕',
                  name: c,
                  conditions: {'cause': c},
                  hint: '${count({'cause': c})} 道',
                ),
            ],
          ),
        );
      }
      if (kps.isNotEmpty) {
        built.add(
          _PaletteGroup(
            title: '知识点',
            items: [
              for (final kp in kps)
                _PaletteItem(
                  icon: '◆',
                  name: kp.name,
                  conditions: {
                    'kpIds': [kp.id],
                  },
                  hint:
                      '${subjectName(kp.subjectId)} · ${count({'kpIds': [kp.id]})} 道',
                ),
            ],
          ),
        );
      }
      if (tags.isNotEmpty) {
        built.add(
          _PaletteGroup(
            title: '标签',
            items: [
              for (final t in tags)
                _PaletteItem(
                  icon: '＃',
                  name: '标签：$t',
                  conditions: {
                    'tags': [t],
                  },
                  hint: '${count({'tags': [t]})} 道',
                ),
            ],
          ),
        );
      }
      if (exams.isNotEmpty) {
        built.add(
          _PaletteGroup(
            title: '试卷',
            items: [
              for (final e in exams)
                _PaletteItem(
                  icon: '▤',
                  name: e.name,
                  conditions: {'examId': e.id},
                  hint: '试卷 · ${count({'examId': e.id})} 道',
                ),
            ],
          ),
        );
      }
      groups = built;
    } catch (_) {
      // 读库失败时面板只显示空态，不抛到调用方。
      groups = const [];
    }
    if (!mounted) return;
    setState(() {
      _groups = groups;
      _loading = false;
      _selected = 0;
    });
  }

  void _applySelected() {
    final visible = _visible;
    if (visible.isEmpty) return;
    final item = visible[_selected.clamp(0, visible.length - 1)];
    _apply(item);
  }

  void _apply(_PaletteItem item) {
    Navigator.of(context).pop();
    widget.onApply(item.conditions, item.name);
  }

  @override
  Widget build(BuildContext context) {
    // 板子色值（mock 内永远浅色，见 B19-BOARD-SPEC §3.2）。
    const hintGrey = Color(0xFF94A3B8);
    const line = Color(0xFFE3E8F0);
    const selectedBg = Color(0xFFE1EDFF);
    final height = MediaQuery.of(context).size.height;
    final visible = _visible;
    final selected = _selected.clamp(0, visible.isEmpty ? 0 : visible.length - 1);
    var flatIndex = -1;
    return Dialog(
      key: const Key('command-palette'),
      alignment: Alignment.topCenter,
      backgroundColor: Colors.white,
      insetPadding: EdgeInsets.only(
        top: height * 0.09,
        left: 24,
        right: 24,
        bottom: 24,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      child: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
              child: TextField(
                key: const Key('command-palette-input'),
                controller: _queryCtrl,
                autofocus: true,
                style: const TextStyle(fontSize: 17, color: Color(0xFF17233B)),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  hintText: '搜文件夹、标签、错因、知识点、试卷…',
                  hintStyle: TextStyle(color: hintGrey),
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                ),
                onChanged: (v) {
                  setState(() {
                    _query = v.trim();
                    _selected = 0;
                  });
                },
                onSubmitted: (_) => _applySelected(),
              ),
            ),
            const Divider(height: 1, color: line),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: height * 0.46),
              child: _loading
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : visible.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(18),
                      child: Text(
                        '没有匹配的查找，换个词试试',
                        style: TextStyle(fontSize: 13.5, color: hintGrey),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.all(8),
                      shrinkWrap: true,
                      children: [
                        for (final g in _visibleGroups) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
                            child: Text(
                              g.title,
                              style: const TextStyle(
                                fontSize: 12,
                                color: hintGrey,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          for (final item in g.items)
                            Builder(
                              builder: (context) {
                                flatIndex++;
                                final idx = flatIndex;
                                final isSelected = idx == selected;
                                return MouseRegion(
                                  onEnter: (_) {
                                    if (_selected != idx) {
                                      setState(() => _selected = idx);
                                    }
                                  },
                                  child: InkWell(
                                    onTap: () => _apply(item),
                                    borderRadius: BorderRadius.circular(8),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 9,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isSelected
                                            ? selectedBg
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Row(
                                        children: [
                                          Text(
                                            item.label,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              color: Color(0xFF17233B),
                                            ),
                                          ),
                                          const Spacer(),
                                          Text(
                                            item.hint,
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: hintGrey,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                        ],
                      ],
                    ),
            ),
            const Divider(height: 1, color: line),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  Text('↑↓ 选择', style: TextStyle(fontSize: 12, color: hintGrey)),
                  SizedBox(width: 14),
                  Text('Enter 打开', style: TextStyle(fontSize: 12, color: hintGrey)),
                  SizedBox(width: 14),
                  Text('Esc 关闭', style: TextStyle(fontSize: 12, color: hintGrey)),
                  Spacer(),
                  Text(
                    '不搜题干文字',
                    style: TextStyle(fontSize: 12, color: hintGrey),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
