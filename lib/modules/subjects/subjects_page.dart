import 'package:flutter/material.dart';

import '../../data/repository.dart';
import '../../models/models.dart';
import '../../theme/app_theme.dart';

/// 学科管理：分段折叠式四段（学科 / 知识点树 / 标签 / 试卷），
/// 默认全折起，一次只展开一个。无文件夹段（文件夹只在错题本目录页管）。
class SubjectsPage extends StatefulWidget {
  const SubjectsPage({super.key, required this.repo});

  final QuestionRepository repo;

  @override
  State<SubjectsPage> createState() => _SubjectsPageState();
}

const _presetFolders = ['试卷', '平时作业', '模拟卷'];
const _newSubjectColors = [
  Color(0xFF2F7CF6),
  Color(0xFF1F9D66),
  Color(0xFFE0524D),
  Color(0xFF7C5CFC),
  Color(0xFFF08A1D),
];

class _SubjectsPageState extends State<SubjectsPage> {
  String? _openSection; // subjects / knowledge / tags / exams
  bool _coverOpen = false;

  List<Subject> _subjects = [];
  Map<String, int> _questionCounts = {};
  List<KnowledgePoint> _kps = [];
  List<String> _tags = [];
  List<Exam> _exams = [];

  String? _kpSubjectId;
  final Set<String> _expandedChapters = {};
  String _examQuery = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final subjects = await widget.repo.subjects();
    final questions = await widget.repo.all(includeArchived: true);
    final counts = <String, int>{};
    for (final q in questions) {
      counts[q.subjectId] = (counts[q.subjectId] ?? 0) + 1;
    }
    final kps = await widget.repo.knowledgePoints();
    final tags = await widget.repo.tags();
    final exams = await widget.repo.exams();
    if (!mounted) return;
    setState(() {
      _subjects = subjects;
      _questionCounts = counts;
      _kps = kps;
      _tags = tags;
      _exams = exams;
      _kpSubjectId ??= subjects.isNotEmpty ? subjects.first.id : 'math';
      _loading = false;
    });
  }

  void _toggleSection(String key) {
    setState(() => _openSection = _openSection == key ? null : key);
  }

  Future<bool> _confirmDelete(String title, String message) async {
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
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<String?> _askText(String title, String label,
      {String initial = ''}) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result.isEmpty) return null;
    return result;
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------- 学科 ----------

  Future<void> _addSubject() async {
    final name = await _askText('添加学科', '学科名');
    if (name == null) return;
    if (_subjects.any((s) => s.name == name)) {
      _snack('已经有了这个学科');
      return;
    }
    final usedColors = _subjects.map((s) => s.color).toSet();
    final color = _newSubjectColors.firstWhere(
      (c) => !usedColors.contains(c),
      orElse: () => _newSubjectColors.first,
    );
    final id = 'subject-${DateTime.now().millisecondsSinceEpoch}';
    final subject = Subject(
      id: id,
      name: name,
      color: color,
      icon: name.isEmpty ? '学' : name[0],
    );
    await widget.repo.saveSubject(subject);
    // 新学科自动获得预置文件夹。
    for (var i = 0; i < _presetFolders.length; i++) {
      await widget.repo.saveFolder(Folder(
        id: 'folder-$id-${_presetFolders[i]}',
        name: _presetFolders[i],
        subjectId: id,
        sortOrder: i,
      ));
    }
    await _load();
  }

  Future<void> _renameSubject(Subject s) async {
    final name = await _askText('改名', '学科名', initial: s.name);
    if (name == null || name == s.name) return;
    await widget.repo.saveSubject(s.copyWith(name: name));
    await _load();
  }

  Future<void> _deleteSubject(Subject s) async {
    final count = _questionCounts[s.id] ?? 0;
    final ok = await _confirmDelete(
      '删除「${s.name}」',
      '删除这个学科会删掉其中全部的题，确定吗？（共 $count 道题）',
    );
    if (!ok) return;
    await widget.repo.deleteSubject(s.id);
    await _load();
  }

  Future<void> _setCover(Subject s,
      {String? style, String? color}) async {
    await widget.repo.saveSubject(s.copyWith(
      coverStyle: style ?? s.coverStyle,
      coverColor: color ?? s.coverColor,
    ));
    await _load();
  }

  // ---------- 知识点 ----------

  List<String> _chaptersFor(String subjectId) {
    final chapters = <String>[];
    for (final kp in _kps) {
      if (kp.subjectId == subjectId && !chapters.contains(kp.chapter)) {
        chapters.add(kp.chapter);
      }
    }
    return chapters;
  }

  Future<void> _addChapter() async {
    final subjectId = _kpSubjectId ?? 'math';
    final chapterController = TextEditingController();
    final kpController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加章节'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: chapterController,
              autofocus: true,
              decoration: const InputDecoration(labelText: '章节名'),
            ),
            TextField(
              controller: kpController,
              decoration: const InputDecoration(labelText: '第一个知识点'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    final chapter = chapterController.text.trim();
    final kpName = kpController.text.trim();
    chapterController.dispose();
    kpController.dispose();
    if (ok != true || chapter.isEmpty || kpName.isEmpty) return;
    await widget.repo.addKnowledgePoint(KnowledgePoint(
      id: 'kp-${DateTime.now().millisecondsSinceEpoch}',
      subjectId: subjectId,
      chapter: chapter,
      name: kpName,
    ));
    setState(() => _expandedChapters.add(chapter));
    await _load();
  }

  Future<void> _addKnowledgePoint(String chapter) async {
    final name = await _askText('添加知识点', '知识点名');
    if (name == null) return;
    await widget.repo.addKnowledgePoint(KnowledgePoint(
      id: 'kp-${DateTime.now().millisecondsSinceEpoch}',
      subjectId: _kpSubjectId ?? 'math',
      chapter: chapter,
      name: name,
    ));
    await _load();
  }

  Future<void> _renameKnowledgePoint(KnowledgePoint kp) async {
    final name = await _askText('改名', '知识点名', initial: kp.name);
    if (name == null || name == kp.name) return;
    await widget.repo.renameKnowledgePoint(kp.id, name);
    await _load();
  }

  Future<void> _deleteKnowledgePoint(KnowledgePoint kp) async {
    final ok = await _confirmDelete('删除知识点', '删了就没了，确定吗？');
    if (!ok) return;
    await widget.repo.deleteKnowledgePoint(kp.id);
    await _load();
  }

  // ---------- 标签 / 试卷 ----------

  Future<void> _renameTag(String oldName) async {
    final name = await _askText('改名', '标签名', initial: oldName);
    if (name == null || name == oldName) return;
    await widget.repo.renameTag(oldName, name);
    await _load();
  }

  Future<void> _deleteTag(String name) async {
    final ok = await _confirmDelete('删除标签', '删了就没了，确定吗？');
    if (!ok) return;
    await widget.repo.deleteTag(name);
    await _load();
  }

  Future<void> _renameExam(Exam e) async {
    final name = await _askText('改名', '试卷名', initial: e.name);
    if (name == null || name == e.name) return;
    await widget.repo.renameExam(e.id, name);
    await _load();
  }

  Future<void> _deleteExam(Exam e) async {
    final ok = await _confirmDelete('删除试卷', '删了就没了，确定吗？');
    if (!ok) return;
    await widget.repo.deleteExam(e.id);
    await _load();
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('学科管理', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 16),
          _section(
            key: 'subjects',
            title: '学科',
            child: _buildSubjects(),
          ),
          _section(
            key: 'knowledge',
            title: '知识点树',
            child: _buildKnowledge(),
          ),
          _section(
            key: 'tags',
            title: '标签',
            child: _buildTags(),
          ),
          _section(
            key: 'exams',
            title: '试卷',
            child: _buildExams(),
          ),
        ],
      ),
    );
  }

  Widget _section(
      {required String key, required String title, required Widget child}) {
    final open = _openSection == key;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => _toggleSection(key),
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

  Widget _rowActions(
      {required VoidCallback onRename, required VoidCallback onDelete}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(onPressed: onRename, child: const Text('改名')),
        TextButton(onPressed: onDelete, child: const Text('删除')),
      ],
    );
  }

  Widget _buildSubjects() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: _addSubject,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.accent,
              side: const BorderSide(color: AppTheme.accent),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('＋ 添加学科'),
          ),
        ),
        const SizedBox(height: 8),
        for (final s in _subjects)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                      color: s.color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.name,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700)),
                      Text('${_questionCounts[s.id] ?? 0} 道题',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                _rowActions(
                  onRename: () => _renameSubject(s),
                  onDelete: () => _deleteSubject(s),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        // 错题本封面样式：本身可折叠，默认折起。
        InkWell(
          onTap: () => setState(() => _coverOpen = !_coverOpen),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                const Text('错题本封面样式',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                const Spacer(),
                Icon(_coverOpen
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down),
              ],
            ),
          ),
        ),
        if (_coverOpen)
          for (final s in _subjects) _buildCoverPicker(s),
      ],
    );
  }

  Widget _buildCoverPicker(Subject s) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration:
                    BoxDecoration(color: s.color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(s.name, style: const TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final style in CoverStyles.all)
                InkWell(
                  onTap: () => _setCover(s, style: style),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    width: 64,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: CoverColors.of(s.coverColor),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: s.coverStyle == style
                            ? AppTheme.accent
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: Text(
                      CoverStyles.labels[style] ?? style,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white,
                          fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            children: [
              for (final color in CoverColors.all)
                InkWell(
                  onTap: () => _setCover(s, color: color),
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: CoverColors.of(color),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: s.coverColor == color
                            ? AppTheme.accent
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: s.coverColor == color
                        ? const Icon(Icons.check,
                            size: 16, color: Colors.white)
                        : null,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildKnowledge() {
    final subjectId = _kpSubjectId ?? 'math';
    final chapters = _chaptersFor(subjectId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: _addChapter,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.accent,
              side: const BorderSide(color: AppTheme.accent),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('＋ 添加章节'),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            for (final s in _subjects)
              ChoiceChip(
                label: Text(s.name),
                selected: subjectId == s.id,
                onSelected: (_) => setState(() {
                  _kpSubjectId = s.id;
                  _expandedChapters.clear();
                }),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (chapters.isEmpty)
          Text('这科还没有知识点，先添加一个章节吧。',
              style: Theme.of(context).textTheme.bodySmall)
        else
          for (final chapter in chapters) ...[
            InkWell(
              onTap: () => setState(() {
                if (_expandedChapters.contains(chapter)) {
                  _expandedChapters.remove(chapter);
                } else {
                  _expandedChapters.add(chapter);
                }
              }),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Text(chapter,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    Icon(_expandedChapters.contains(chapter)
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down),
                  ],
                ),
              ),
            ),
            if (_expandedChapters.contains(chapter)) ...[
              for (final kp in _kps.where((k) =>
                  k.subjectId == subjectId && k.chapter == chapter))
                Padding(
                  padding:
                      const EdgeInsets.only(left: 12, top: 2, bottom: 2),
                  child: Row(
                    children: [
                      Expanded(child: Text(kp.name)),
                      _rowActions(
                        onRename: () => _renameKnowledgePoint(kp),
                        onDelete: () => _deleteKnowledgePoint(kp),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 8),
                child: TextButton(
                  onPressed: () => _addKnowledgePoint(chapter),
                  child: const Text('＋ 添加知识点'),
                ),
              ),
            ],
          ],
      ],
    );
  }

  Widget _buildTags() {
    return _AddListSection(
      hint: '新标签名',
      addLabel: '添加',
      onAdd: (name) async {
        if (_tags.contains(name)) {
          _snack('已经有了这个标签');
          return;
        }
        await widget.repo.addTag(name);
        await _load();
      },
      rows: [
        for (final t in _tags)
          _NameRow(
            name: t,
            onRename: () => _renameTag(t),
            onDelete: () => _deleteTag(t),
          ),
      ],
    );
  }

  Widget _buildExams() {
    final query = _examQuery.trim();
    final filtered = query.isEmpty
        ? _exams
        : _exams.where((e) => e.name.contains(query)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          decoration: const InputDecoration(
            hintText: '按试卷名搜索',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (v) => setState(() => _examQuery = v),
        ),
        const SizedBox(height: 8),
        _AddListSection(
          hint: '新试卷名',
          addLabel: '添加',
          onAdd: (name) async {
            if (_exams.any((e) => e.name == name)) {
              _snack('已经有了这张试卷');
              return;
            }
            await widget.repo.addExam(Exam(
              id: 'exam-${DateTime.now().millisecondsSinceEpoch}',
              name: name,
            ));
            await _load();
          },
          rows: const [],
        ),
        const SizedBox(height: 4),
        if (filtered.isEmpty && query.isNotEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('没找到这张试卷，换个词试试'),
          )
        else
          for (final e in filtered)
            _NameRow(
              name: e.name,
              subtitle: e.date == null
                  ? null
                  : '${e.date!.year}-${e.date!.month}-${e.date!.day}',
              onRename: () => _renameExam(e),
              onDelete: () => _deleteExam(e),
            ),
      ],
    );
  }
}

class _NameRow extends StatelessWidget {
  const _NameRow({
    required this.name,
    this.subtitle,
    required this.onRename,
    required this.onDelete,
  });

  final String name;
  final String? subtitle;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(fontSize: 15)),
                if (subtitle != null)
                  Text(subtitle!,
                      style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          TextButton(onPressed: onRename, child: const Text('改名')),
          TextButton(onPressed: onDelete, child: const Text('删除')),
        ],
      ),
    );
  }
}

class _AddListSection extends StatefulWidget {
  const _AddListSection({
    required this.hint,
    required this.addLabel,
    required this.onAdd,
    required this.rows,
  });

  final String hint;
  final String addLabel;
  final Future<void> Function(String name) onAdd;
  final List<Widget> rows;

  @override
  State<_AddListSection> createState() => _AddListSectionState();
}

class _AddListSectionState extends State<_AddListSection> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                decoration: InputDecoration(
                  hintText: widget.hint,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => _submit(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _submit,
              child: Text(widget.addLabel),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ...widget.rows,
      ],
    );
  }

  Future<void> _submit() async {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    _controller.clear();
    await widget.onAdd(name);
  }
}
