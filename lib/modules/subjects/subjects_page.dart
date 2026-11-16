import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repository.dart';
import '../../state/repository_provider.dart';
import '../../state/subjects_notifier.dart';
import '../../models/models.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/uikit.dart';

/// 学科管理：分段折叠式四段（学科 / 知识点树 / 标签 / 试卷），
/// 默认全折起，一次只展开一个。无文件夹段（文件夹只在错题本目录页管）。
///
/// 结构与文案以 HTML 原型 `viewSubjects()` 为准（R0 附录 A）：
/// 学科段顶部是「新学科名输入 + ＋ 添加学科」，每行色点 + 学科名 +
/// 「N 道题」+ 改名/删除；删学科是模态弹窗确认（B3；长文案，含题数与文件夹
/// 后果）；组内可折叠的「错题本封面样式」块每科 6 样式 × 7 色，点即生效。
/// 知识点树按学科页签一次只看一科（默认数学），章节默认折起，章节行与
/// 知识点行都有改名/删除；「＋ 添加章节」在顶部（章节只随知识点存在，
/// 加章节须同时给第一个知识点，不改 Schema）、「＋ 添加知识点」在每
/// 展开章节底部。标签/试卷段顶部添加；试卷段顶部有搜索框，无匹配显示
/// 「没找到这张试卷，换个词试试」。
///
/// D5：Flutter 侧 grep 确认——学科管理里根本没有换图标、隐藏学科、
/// 学科排序的处理逻辑与残留代码（Subject 模型也没有 hidden/icon/
/// order 字段），只有新增/删除/改名；相关错误提示也不暗示不存在的
/// 功能。所以 D5 在本页无代码可删（见 R10-REPORT §6）。
/// 学科管理页（ARCH-PLAN-A 第 2 阶段）：外壳只负责把构造器接到的
/// `repo` 注入 `repositoryProvider`（`app.dart` 仍传 `repo:` 进来，
/// 本阶段不碰 `app.dart`，故保留该参数；Provider 的默认值与
/// 根组件是同一单例库）。业务数据与管理逻辑在 `subjectsProvider`
///（`lib/state/subjects_notifier.dart`），内层 `_SubjectsView` 是
/// `ConsumerStatefulWidget`，只留 widget 与纯界面临时状态。
class SubjectsPage extends StatefulWidget {
  const SubjectsPage({super.key, required this.repo});

  final QuestionRepository repo;

  @override
  State<SubjectsPage> createState() => _SubjectsPageState();
}

class _SubjectsPageState extends State<SubjectsPage> {
  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(widget.repo)],
      child: const _SubjectsView(),
    );
  }
}

class _SubjectsView extends ConsumerStatefulWidget {
  const _SubjectsView();

  @override
  ConsumerState<_SubjectsView> createState() => _SubjectsViewState();
}

class _SubjectsViewState extends ConsumerState<_SubjectsView> {
  /// 业务数据（读）：只在 build 里用（`ref.watch` 只能在 build 里调）。
  SubjectsState get _s => ref.watch(subjectsProvider);

  /// 业务数据（读）：事件回调里用（`ref.read`，不订阅重建）。
  SubjectsState get _sr => ref.read(subjectsProvider);

  /// 业务逻辑（写）：事件回调里用。
  SubjectsNotifier get _n => ref.read(subjectsProvider.notifier);

  String? _openSection; // subjects / knowledge / tags / exams
  bool _coverOpen = false;
  bool _errorDismissed = false;

  final Set<String> _expandedChapters = {};
  String _examQuery = '';

  // 内联新增输入。
  final _newSubjectController = TextEditingController();
  final _newTagController = TextEditingController();
  final _newExamController = TextEditingController();
  final _examSearchController = TextEditingController();
  final _newChapterController = TextEditingController();
  final _newChapterKpController = TextEditingController();
  final _newKpController = TextEditingController();
  bool _addingChapter = false;
  String? _kpAddChapter; // 正在输新知识点的章节
  DateTime _newExamDate = DateTime.now();

  // 内联改名：同一时间只改一项，target 形如 subject:<id> /
  // chapter:<subjectId>|<章节> / kp:<id> / tag:<名> / exam:<id>。
  final _editController = TextEditingController();
  String? _editTarget;

  @override
  void dispose() {
    _newSubjectController.dispose();
    _newTagController.dispose();
    _newExamController.dispose();
    _examSearchController.dispose();
    _newChapterController.dispose();
    _newChapterKpController.dispose();
    _newKpController.dispose();
    _editController.dispose();
    super.dispose();
  }

  void _toggleSection(String key) {
    setState(() => _openSection = _openSection == key ? null : key);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------- 内联改名 ----------

  void _startEdit(String target, String initial) {
    setState(() {
      _editTarget = target;
      _editController.text = initial;
    });
  }

  Future<void> _saveEdit() async {
    final target = _editTarget;
    if (target == null) return;
    final name = _editController.text.trim();
    if (name.isEmpty) {
      _snack('名字不能为空');
      return;
    }
    final parts = target.split(':');
    final kind = parts[0];
    final key = parts.sublist(1).join(':');
    setState(() => _editTarget = null);
    switch (kind) {
      case 'subject':
        final r = await _n.renameSubject(key, name);
        if (r.message != null) _snack(r.message!);
      case 'chapter':
        final sep = key.indexOf('|');
        final subjectId = key.substring(0, sep);
        final oldChapter = key.substring(sep + 1);
        final r = await _n.renameChapter(subjectId, oldChapter, name);
        if (r.message != null) {
          _snack(r.message!);
        } else if (r.saved) {
          setState(() {
            _expandedChapters.remove(oldChapter);
            _expandedChapters.add(name);
          });
        }
      case 'kp':
        final r = await _n.renameKnowledgePoint(key, name);
        if (r.message != null) _snack(r.message!);
      case 'tag':
        final r = await _n.renameTag(key, name);
        if (r.message != null) _snack(r.message!);
      case 'exam':
        final r = await _n.renameExam(key, name);
        if (r.message != null) _snack(r.message!);
    }
  }

  // ---------- 删除确认（B3：模态 AlertDialog 弹窗） ----------

  /// 删除确认弹窗：只统一形式，标题/后果文案/确认按钮文案沿用原来
  /// 行内确认条的字句；确认后走 [_deleteConfirmed] 按 target 执行删除。
  Future<void> _askDelete({
    required String target,
    required String title,
    required String detail,
    required String confirmLabel,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(detail),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    if (ok == true && mounted) await _deleteConfirmed(target);
  }

  Future<void> _deleteConfirmed(String target) async {
    final parts = target.split(':');
    final kind = parts[0];
    final key = parts.sublist(1).join(':');
    switch (kind) {
      case 'subject':
        await _n.deleteSubject(key);
      case 'chapter':
        final sep = key.indexOf('|');
        final subjectId = key.substring(0, sep);
        final chapter = key.substring(sep + 1);
        await _n.deleteChapter(subjectId, chapter);
        setState(() => _expandedChapters.remove(chapter));
      case 'kp':
        await _n.deleteKnowledgePoint(key);
      case 'tag':
        await _n.deleteTag(key);
      case 'exam':
        await _n.deleteExam(key);
    }
  }

  // ---------- 学科 ----------

  Future<void> _addSubject() async {
    final name = _newSubjectController.text.trim();
    if (name.isEmpty) return;
    final r = await _n.addSubject(name);
    if (r.message != null) {
      _snack(r.message!);
      return;
    }
    _newSubjectController.clear();
  }

  Future<void> _setCover(Subject s, {String? style, String? color}) async {
    await _n.setCover(s, style: style, color: color);
  }

  // ---------- 知识点 ----------

  Future<void> _addChapter() async {
    final subjectId = _sr.kpSubjectId ?? 'math';
    final chapter = _newChapterController.text.trim();
    final kpName = _newChapterKpController.text.trim();
    if (chapter.isEmpty || kpName.isEmpty) {
      _snack('章节名和第一个知识点都要填');
      return;
    }
    final r = await _n.addChapter(
      subjectId: subjectId,
      chapter: chapter,
      kpName: kpName,
    );
    if (r.message != null) {
      _snack(r.message!);
      return;
    }
    setState(() {
      _expandedChapters.add(chapter);
      _addingChapter = false;
      _newChapterController.clear();
      _newChapterKpController.clear();
    });
  }

  Future<void> _addKnowledgePoint(String chapter) async {
    final name = _newKpController.text.trim();
    if (name.isEmpty) return;
    await _n.addKnowledgePoint(
      subjectId: _sr.kpSubjectId ?? 'math',
      chapter: chapter,
      name: name,
    );
    _newKpController.clear();
    setState(() => _kpAddChapter = null);
  }

  // ---------- 标签 / 试卷 ----------

  Future<void> _addTag() async {
    final name = _newTagController.text.trim();
    if (name.isEmpty) return;
    final r = await _n.addTag(name);
    if (r.message != null) {
      _snack(r.message!);
      return;
    }
    _newTagController.clear();
  }

  Future<void> _addExam() async {
    final name = _newExamController.text.trim();
    if (name.isEmpty) return;
    final r = await _n.addExam(name, _newExamDate);
    if (r.message != null) {
      _snack(r.message!);
      return;
    }
    _newExamController.clear();
  }

  Future<void> _pickExamDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _newExamDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() => _newExamDate = picked);
  }

  String _dateText(DateTime? d) => d == null
      ? ''
      : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    if (_s.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final scale = qmScaleOf(context);
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('学科管理', style: Theme.of(context).textTheme.titleLarge),
          SizedBox(height: 14 * scale),
          if (_s.loadError && !_errorDismissed)
            QmBanner(
              tone: QmBannerTone.error,
              message: '学科管理读取失败，已显示默认内容。修改前请先重启应用。',
              onDismiss: () => setState(() => _errorDismissed = true),
            ),
          QmFoldSection(
            title: '学科',
            expanded: _openSection == 'subjects',
            onToggle: () => _toggleSection('subjects'),
            child: _buildSubjects(),
          ),
          SizedBox(height: R10Tokens.settingsGroupGap * scale),
          QmFoldSection(
            title: '知识点树',
            expanded: _openSection == 'knowledge',
            onToggle: () => _toggleSection('knowledge'),
            child: _buildKnowledge(),
          ),
          SizedBox(height: R10Tokens.settingsGroupGap * scale),
          QmFoldSection(
            title: '标签',
            expanded: _openSection == 'tags',
            onToggle: () => _toggleSection('tags'),
            child: _buildTags(),
          ),
          SizedBox(height: R10Tokens.settingsGroupGap * scale),
          QmFoldSection(
            title: '试卷',
            expanded: _openSection == 'exams',
            onToggle: () => _toggleSection('exams'),
            child: _buildExams(),
          ),
        ],
      ),
    );
  }

  /// 内联改名行：输入框 + 保存改名 + 取消（HTML 行内改名形态）。
  Widget _editRow({required String confirmLabel}) {
    final scale = qmScaleOf(context);
    return Row(
      children: [
        Expanded(
          child: QmTextField(
            controller: _editController,
            autofocus: true,
            onSubmitted: (_) => _saveEdit(),
          ),
        ),
        SizedBox(width: 8 * scale),
        QmButton(
          label: confirmLabel,
          size: QmButtonSize.small,
          onPressed: _saveEdit,
        ),
        SizedBox(width: 8 * scale),
        QmButton(
          label: '取消',
          variant: QmButtonVariant.plain,
          size: QmButtonSize.small,
          onPressed: () => setState(() => _editTarget = null),
        ),
      ],
    );
  }

  Widget _rowActions({
    required String editTarget,
    required String editInitial,
    required VoidCallback onDelete,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        QmButton(
          label: '改名',
          variant: QmButtonVariant.plain,
          size: QmButtonSize.small,
          onPressed: () => _startEdit(editTarget, editInitial),
        ),
        const SizedBox(width: 8),
        QmButton(
          label: '删除',
          variant: QmButtonVariant.danger,
          size: QmButtonSize.small,
          onPressed: onDelete,
        ),
      ],
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

  Widget _buildSubjects() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: QmTextField(
                controller: _newSubjectController,
                hintText: '新学科名称，如：物理',
                onSubmitted: (_) => _addSubject(),
              ),
            ),
            SizedBox(width: 8 * scale),
            QmButton(
              label: '＋ 添加学科',
              size: QmButtonSize.small,
              onPressed: _addSubject,
            ),
          ],
        ),
        SizedBox(height: 8 * scale),
        if (_s.subjects.isEmpty) _noteText('还没有学科，先添加一个吧。'),
        for (final s in _s.subjects) ...[
          if (_editTarget == 'subject:${s.id}')
            Padding(
              padding: EdgeInsets.symmetric(
                vertical: R10Tokens.subjectRowPaddingV * scale,
              ),
              child: Row(
                children: [
                  Container(
                    width: R10Tokens.subjectDotSize * scale,
                    height: R10Tokens.subjectDotSize * scale,
                    decoration: BoxDecoration(
                      color: DesignTokens.subjectColor(
                        s.id,
                        Theme.of(context).brightness,
                        s.color,
                      ),
                      shape: BoxShape.circle,
                    ),
                  ),
                  SizedBox(width: 10 * scale),
                  Expanded(child: _editRow(confirmLabel: '保存改名')),
                ],
              ),
            )
          else
            Padding(
              padding: EdgeInsets.symmetric(
                vertical: R10Tokens.subjectRowPaddingV * scale,
              ),
              child: Row(
                children: [
                  Container(
                    width: R10Tokens.subjectDotSize * scale,
                    height: R10Tokens.subjectDotSize * scale,
                    decoration: BoxDecoration(
                      color: DesignTokens.subjectColor(
                        s.id,
                        Theme.of(context).brightness,
                        s.color,
                      ),
                      shape: BoxShape.circle,
                    ),
                  ),
                  SizedBox(width: 10 * scale),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.name,
                          style: const TextStyle(
                            fontSize: R10Tokens.subjectNameFontSize,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '${_s.questionCounts[s.id] ?? 0} 道题',
                          style: TextStyle(
                            fontSize: R10Tokens.subjectCountFontSize,
                            color: palette.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _rowActions(
                    editTarget: 'subject:${s.id}',
                    editInitial: s.name,
                    onDelete: () => _askDelete(
                      target: 'subject:${s.id}',
                      title: '删除学科「${s.name}」，确定吗？',
                      detail:
                          '删除这个学科会删掉其中全部的题——这一科现在有 ${_s.questionCounts[s.id] ?? 0} 道题，会全部一起删掉；这一科自己的文件夹也跟着一起删掉（其他科目的文件夹不受影响），删了就没了，确定吗？',
                      confirmLabel:
                          '确认删除这一科和全部 ${_s.questionCounts[s.id] ?? 0} 道题',
                    ),
                  ),
                ],
              ),
            ),
        ],
        SizedBox(height: 12 * scale),
        QmFoldSection(
          title: '错题本封面样式',
          variant: QmFoldVariant.form,
          expanded: _coverOpen,
          onToggle: () => setState(() => _coverOpen = !_coverOpen),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _noteText('每科一本、每科单独换：点样式小图换样式，点下面的颜色换封面颜色，样式和颜色能任意搭配，换完立即生效。'),
              SizedBox(height: 8 * scale),
              for (final s in _s.subjects) _buildCoverPicker(s),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCoverPicker(Subject s) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final firstChar = s.name.isEmpty ? '学' : s.name[0];
    return Padding(
      padding: EdgeInsets.only(bottom: 16 * scale),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8 * scale,
                height: 8 * scale,
                decoration: BoxDecoration(
                  color: DesignTokens.subjectColor(
                    s.id,
                    Theme.of(context).brightness,
                    s.color,
                  ),
                  shape: BoxShape.circle,
                ),
              ),
              SizedBox(width: 8 * scale),
              Text(s.name,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              SizedBox(width: 8 * scale),
              Expanded(
                child: Text(
                  '当前封面：${CoverStyles.labels[s.coverStyle] ?? '纯色折角'} · ${CoverColors.labels[s.coverColor] ?? '蓝'}色',
                  style: TextStyle(
                    fontSize: R10Tokens.settingsRowDescFontSize,
                    color: palette.muted,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 8 * scale),
          Wrap(
            spacing: 8 * scale,
            runSpacing: 8 * scale,
            children: [
              for (final style in CoverStyles.all)
                // 封面样式只接一处点按（SR-P2-55）：留外层 GestureDetector
                //（小图 + 下方样式名签整个格子都可点，名签点按是既有
                // 交互，见封面样式测试），QmCoverMini 不再另传 onTap——
                // onTap 为 null 时它只返回装饰容器，不装点按识别器，
                // 不与外层竞争。
                GestureDetector(
                  onTap: () => _setCover(s, style: style),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      QmCoverMini(
                        style: style,
                        color: CoverTokens.of(s.coverColor),
                        character: firstChar,
                        selected: s.coverStyle == style,
                      ),
                      SizedBox(height: 4 * scale),
                      Text(
                        CoverStyles.labels[style] ?? style,
                        style: TextStyle(
                          fontSize: R10Tokens.coverPickLabelFontSize,
                          fontWeight: FontWeight.w700,
                          color: palette.ink2,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          SizedBox(height: 8 * scale),
          Wrap(
            spacing: 10 * scale,
            runSpacing: 8 * scale,
            children: [
              Text(
                '封面颜色',
                style: TextStyle(
                  fontSize: R10Tokens.settingsRowDescFontSize,
                  color: palette.muted,
                ),
              ),
              for (final colorKey in CoverColors.all)
                GestureDetector(
                  onTap: () => _setCover(s, color: colorKey),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: R10Tokens.coverSwatchSize * scale,
                        height: R10Tokens.coverSwatchSize * scale,
                        decoration: BoxDecoration(
                          color: CoverTokens.of(colorKey),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: s.coverColor == colorKey
                                ? palette.accent
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: s.coverColor == colorKey
                            ? const QmGlyph(
                                QmGlyphs.check,
                                size: 13,
                                color: Colors.white,
                              )
                            : null,
                      ),
                      SizedBox(width: 4 * scale),
                      Text(
                        CoverColors.labels[colorKey] ?? colorKey,
                        style: TextStyle(
                          fontSize: R10Tokens.coverPickLabelFontSize,
                          fontWeight: s.coverColor == colorKey
                              ? FontWeight.w700
                              : FontWeight.w400,
                          color: palette.ink2,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildKnowledge() {
    final scale = qmScaleOf(context);
    final subjectId = _s.kpSubjectId ?? 'math';
    final chapters = _s.chaptersFor(subjectId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8 * scale,
          runSpacing: 8 * scale,
          children: [
            for (final s in _s.subjects)
              QmChip(
                label: s.name,
                subjectId: s.id,
                storedColor: s.color,
                selected: subjectId == s.id,
                onTap: () {
                  _n.selectKpSubject(s.id);
                  setState(() {
                    _expandedChapters.clear();
                    _addingChapter = false;
                    _kpAddChapter = null;
                  });
                },
              ),
          ],
        ),
        SizedBox(height: 12 * scale),
        Align(
          alignment: Alignment.centerLeft,
          child: QmButton(
            label: '＋ 添加章节',
            variant: QmButtonVariant.secondary,
            size: QmButtonSize.small,
            onPressed: () =>
                setState(() => _addingChapter = !_addingChapter),
          ),
        ),
        if (_addingChapter) ...[
          SizedBox(height: 8 * scale),
          QmTextField(
            controller: _newChapterController,
            hintText: '新章节名称',
            autofocus: true,
          ),
          SizedBox(height: 8 * scale),
          QmTextField(controller: _newChapterKpController, hintText: '第一个知识点'),
          SizedBox(height: 8 * scale),
          Row(
            children: [
              QmButton(
                label: '添加章节',
                size: QmButtonSize.small,
                onPressed: _addChapter,
              ),
              SizedBox(width: 8 * scale),
              QmButton(
                label: '取消',
                variant: QmButtonVariant.plain,
                size: QmButtonSize.small,
                onPressed: () => setState(() {
                  _addingChapter = false;
                  _newChapterController.clear();
                  _newChapterKpController.clear();
                }),
              ),
            ],
          ),
        ],
        SizedBox(height: 8 * scale),
        if (_s.subjects.isEmpty)
          _noteText('还没有学科，先在「学科」段里添加学科，这里就出现它的知识点树。')
        else if (chapters.isEmpty)
          _noteText('「${_s.subjectName(subjectId)}」还没有章节，用上面「＋ 添加章节」加第一个。')
        else
          for (final chapter in chapters) ...[
            _buildChapterRow(subjectId, chapter),
          ],
      ],
    );
  }

  Widget _buildChapterRow(String subjectId, String chapter) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final open = _expandedChapters.contains(chapter);
    final key = '$subjectId|$chapter';
    final kps = _s.kps
        .where((k) => k.subjectId == subjectId && k.chapter == chapter)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_editTarget == 'chapter:$key')
          Padding(
            padding: EdgeInsets.symmetric(vertical: 8 * scale),
            child: _editRow(confirmLabel: '保存改名'),
          )
        else
          Padding(
            padding: EdgeInsets.symmetric(vertical: 8 * scale),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() {
                      if (open) {
                        _expandedChapters.remove(chapter);
                      } else {
                        _expandedChapters.add(chapter);
                      }
                    }),
                    child: Row(
                      children: [
                        QmGlyph(
                          open
                              ? QmGlyphs.chevronDown
                              : QmGlyphs.chevronRightSmall,
                          size: 15,
                          color: palette.muted,
                        ),
                        SizedBox(width: 6 * scale),
                        Flexible(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: chapter,
                                  style: const TextStyle(
                                    fontSize: R10Tokens.kpChapterFontSize,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                TextSpan(
                                  text: ' · ${kps.length} 个知识点',
                                  style: TextStyle(
                                    fontSize: R10Tokens.subjectCountFontSize,
                                    fontWeight: FontWeight.w600,
                                    color: palette.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                _rowActions(
                  editTarget: 'chapter:$key',
                  editInitial: chapter,
                  onDelete: () => _askDelete(
                    target: 'chapter:$key',
                    title: '删除章节「$chapter」，确定吗？',
                    detail:
                        '会删掉这个章节下的 ${kps.length} 个知识点；题还在，只是这些知识点变空、成为待补充，删了就没了，确定吗？',
                    confirmLabel: '确认删除',
                  ),
                ),
              ],
            ),
          ),
        if (open) ...[
          if (kps.isEmpty)
            Padding(
              padding: EdgeInsets.only(
                left: R10Tokens.kpIndent * scale,
                bottom: 4 * scale,
              ),
              child: _noteText('这个章节还没有知识点，用下面加第一个。'),
            ),
          for (final kp in kps) ...[
            if (_editTarget == 'kp:${kp.id}')
              Padding(
                padding: EdgeInsets.only(
                  left: R10Tokens.kpIndent * scale,
                  top: 2 * scale,
                  bottom: 2 * scale,
                ),
                child: _editRow(confirmLabel: '保存改名'),
              )
            else
              Padding(
                padding: EdgeInsets.only(
                  left: R10Tokens.kpIndent * scale,
                  top: 2 * scale,
                  bottom: 2 * scale,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        kp.name,
                        style: const TextStyle(
                          fontSize: R10Tokens.kpNameFontSize,
                        ),
                      ),
                    ),
                    _rowActions(
                      editTarget: 'kp:${kp.id}',
                      editInitial: kp.name,
                      onDelete: () => _askDelete(
                        target: 'kp:${kp.id}',
                        title: '删除知识点「${kp.name}」，确定吗？',
                        detail: '题还在，只是这个知识点变空、成为待补充，删了就没了，确定吗？',
                        confirmLabel: '确认删除',
                      ),
                    ),
                  ],
                ),
              ),
          ],
          Padding(
            padding: EdgeInsets.only(
              left: R10Tokens.kpIndent * scale,
              bottom: 8 * scale,
            ),
            child: _kpAddChapter == chapter
                ? Row(
                    children: [
                      Expanded(
                        child: QmTextField(
                          controller: _newKpController,
                          hintText: '新知识点名称',
                          autofocus: true,
                          onSubmitted: (_) => _addKnowledgePoint(chapter),
                        ),
                      ),
                      SizedBox(width: 8 * scale),
                      QmButton(
                        label: '添加',
                        size: QmButtonSize.small,
                        onPressed: () => _addKnowledgePoint(chapter),
                      ),
                      SizedBox(width: 8 * scale),
                      QmButton(
                        label: '取消',
                        variant: QmButtonVariant.plain,
                        size: QmButtonSize.small,
                        onPressed: () => setState(() {
                          _kpAddChapter = null;
                          _newKpController.clear();
                        }),
                      ),
                    ],
                  )
                : QmButton(
                    label: '＋ 添加知识点',
                    variant: QmButtonVariant.secondary,
                    size: QmButtonSize.small,
                    onPressed: () =>
                        setState(() => _kpAddChapter = chapter),
                  ),
          ),
        ],
      ],
    );
  }

  Widget _buildTags() {
    final scale = qmScaleOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: QmTextField(
                controller: _newTagController,
                hintText: '新标签名称',
                onSubmitted: (_) => _addTag(),
              ),
            ),
            SizedBox(width: 8 * scale),
            QmButton(
              label: '＋ 添加标签',
              size: QmButtonSize.small,
              onPressed: _addTag,
            ),
          ],
        ),
        SizedBox(height: 8 * scale),
        if (_s.tags.isNotEmpty)
          Wrap(
            spacing: 8 * scale,
            runSpacing: 8 * scale,
            children: [
              for (final t in _s.tags)
                QmChip(label: '#$t', displayOnly: true),
            ],
          ),
        SizedBox(height: 4 * scale),
        if (_s.tags.isEmpty) _noteText('还没有标签，先添加一个吧。'),
        for (final t in _s.tags) ...[
          if (_editTarget == 'tag:$t')
            Padding(
              padding: EdgeInsets.symmetric(vertical: 4 * scale),
              child: _editRow(confirmLabel: '保存改名'),
            )
          else
            Padding(
              padding: EdgeInsets.symmetric(vertical: 4 * scale),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '#$t · ${_s.tagCounts[t] ?? 0} 道',
                      style: const TextStyle(
                        fontSize: R10Tokens.subjectNameFontSize,
                      ),
                    ),
                  ),
                  _rowActions(
                    editTarget: 'tag:$t',
                    editInitial: t,
                    onDelete: () => _askDelete(
                      target: 'tag:$t',
                      title: '删除标签「$t」，确定吗？',
                      detail: '题还在，这个标签变空、成为待补充，删了就没了，确定吗？',
                      confirmLabel: '确认删除',
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildExams() {
    final scale = qmScaleOf(context);
    final query = _examQuery.trim();
    final filtered = query.isEmpty
        ? _s.exams
        : _s.exams
            .where((e) => e.name.toLowerCase().contains(query.toLowerCase()))
            .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        QmTextField(
          controller: _examSearchController,
          hintText: '输入试卷名搜试卷',
          onChanged: (v) => setState(() => _examQuery = v),
        ),
        SizedBox(height: 8 * scale),
        Row(
          children: [
            Expanded(
              child: QmTextField(
                controller: _newExamController,
                hintText: '新试卷名称',
                onSubmitted: (_) => _addExam(),
              ),
            ),
            SizedBox(width: 8 * scale),
            QmButton(
              label: _dateText(_newExamDate),
              variant: QmButtonVariant.secondary,
              size: QmButtonSize.small,
              onPressed: _pickExamDate,
            ),
            SizedBox(width: 8 * scale),
            QmButton(
              label: '＋ 添加试卷',
              size: QmButtonSize.small,
              onPressed: _addExam,
            ),
          ],
        ),
        SizedBox(height: 8 * scale),
        if (filtered.isEmpty && query.isNotEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('没找到这张试卷，换个词试试'),
          )
        else if (filtered.isEmpty)
          _noteText('还没有试卷，先添加一张吧。')
        else
          for (final e in filtered) ...[
            if (_editTarget == 'exam:${e.id}')
              Padding(
                padding: EdgeInsets.symmetric(vertical: 4 * scale),
                child: _editRow(confirmLabel: '保存改名'),
              )
            else
              Padding(
                padding: EdgeInsets.symmetric(vertical: 4 * scale),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        e.date == null
                            ? '${e.name} · ${_s.examCounts[e.id] ?? 0} 道题来自这张试卷'
                            : '${e.name} · ${_dateText(e.date)} · ${_s.examCounts[e.id] ?? 0} 道题来自这张试卷',
                        style: const TextStyle(
                          fontSize: R10Tokens.subjectNameFontSize,
                        ),
                      ),
                    ),
                    _rowActions(
                      editTarget: 'exam:${e.id}',
                      editInitial: e.name,
                      onDelete: () => _askDelete(
                        target: 'exam:${e.id}',
                        title: '删除试卷「${e.name}」，确定吗？',
                        detail: '题还在，来源变空、成为待补充，删了就没了，确定吗？',
                        confirmLabel: '确认删除',
                      ),
                    ),
                  ],
                ),
              ),
          ],
      ],
    );
  }
}
