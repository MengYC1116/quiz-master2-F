part of 'wrongbook_page.dart';

// 目录页视图：文件夹树、目录工具条、移动选择条、文件夹行与拖拽落点。

extension _WrongbookDirectoryBuild on _WrongbookPageState {
  Widget _buildDirectory() {
    final subjectId = _subjectId!;
    final subject = _subjectOf(subjectId);
    final tops = _topFolders(subjectId);
    final kw = _folderSearch.trim().toLowerCase();
    final visibleTops = kw.isEmpty
        ? tops
        : tops.where((f) {
            if (f.name.toLowerCase().contains(kw)) return true;
            return _subFolders(f.id)
                .any((s) => s.name.toLowerCase().contains(kw));
          }).toList();
    // 搜到子文件夹时，它的父文件夹自动展开（不写回 _expandedFolders，
    // 展开状态不记住）。
    final effectiveExpanded = {..._expandedFolders};
    if (kw.isNotEmpty) {
      for (final f in visibleTops) {
        if (_subFolders(f.id).any((s) => s.name.toLowerCase().contains(kw))) {
          effectiveExpanded.add(f.id);
        }
      }
    }
    final scale = qmScaleOf(context);
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _pageTitle('${subject.name} · 错题本')),
              QmButton(
                label: '返回书架',
                variant: QmButtonVariant.plain,
                onPressed: _openShelf,
              ),
            ],
          ),
          SizedBox(height: 14 * scale),
          _buildDirectoryTools(),
          if (_selectingMove) _buildMoveSelBar(),
          SizedBox(height: 12 * scale),
          _openBookFrame(
            subjectId: subjectId,
            child: _paperBox(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildAllRow(),
                  for (var i = 0; i < visibleTops.length; i++) ...[
                    _buildGapTarget(null, i),
                    _buildFolderRow(visibleTops[i], 0, effectiveExpanded),
                    if (effectiveExpanded.contains(visibleTops[i].id))
                      _buildKids(visibleTops[i], kw, effectiveExpanded),
                  ],
                  _buildGapTarget(null, visibleTops.length),
                  if (visibleTops.isEmpty)
                    Padding(
                      padding: EdgeInsets.only(
                        top: 28 * scale,
                        bottom: 24 * scale,
                      ),
                      child: Center(
                        child: Text(
                          kw.isEmpty ? '还没有文件夹，新建一个吧' : '没找到这个文件夹，换个词试试',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: DesignTokens.of(Theme.of(context).brightness)
                                .paperMuted,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDirectoryTools() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 40 * scale,
            child: TextField(
              controller: _folderSearchCtrl,
              decoration: InputDecoration(
                hintText: '搜索文件夹',
                hintStyle: TextStyle(color: palette.muted),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12 * scale,
                  vertical: 9 * scale,
                ),
              ),
              onChanged: (v) => _update(() => _folderSearch = v),
            ),
          ),
        ),
        SizedBox(width: 8 * scale),
        SizedBox(
          width: 200 * scale,
          height: 40 * scale,
          child: TextField(
            controller: _newFolderCtrl,
            decoration: InputDecoration(
              hintText: '新文件夹名称',
              hintStyle: TextStyle(color: palette.muted),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(
                horizontal: 12 * scale,
                vertical: 9 * scale,
              ),
            ),
            onSubmitted: (_) => _addFolder(),
          ),
        ),
        SizedBox(width: 8 * scale),
        QmButton(
          label: '加文件夹',
          size: QmButtonSize.small,
          onPressed: () => _addFolder(),
        ),
        SizedBox(width: 8 * scale),
        QmButton(
          label: _selectingMove ? '退出选择' : '选择文件夹',
          variant: QmButtonVariant.plain,
          size: QmButtonSize.small,
          onPressed: () => _update(() {
            _selectingMove = !_selectingMove;
            if (!_selectingMove) _moveSelection.clear();
          }),
        ),
      ],
    );
  }

  Widget _buildMoveSelBar() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final subjectId = _subjectId!;
    final tops = _topFolders(subjectId);
    final selN = _moveSelection.length;
    // SR2-7：下拉当前值必须在选项里——与批量条同款防线
    //（wrongbook_list.dart _buildBatchBar），不在 build 里写回状态。
    // _moveTargetId 可能陈旧：换科后仍是上一科文件夹的 id、目标被删
    // 或被拖成子文件夹后不在当前科顶层里，直接喂给 DropdownButton
    // 会在 debug 下断言；无效时回落到“移到顶层”。
    final effectiveTargetId =
        _moveTargetId == '__top__' || tops.any((f) => f.id == _moveTargetId)
            ? _moveTargetId
            : '__top__';
    return Container(
      margin: EdgeInsets.only(top: 12 * scale),
      padding: EdgeInsets.symmetric(
        horizontal: 12 * scale,
        vertical: 10 * scale,
      ),
      decoration: BoxDecoration(
        color: palette.surface2,
        border: Border.all(color: palette.line),
        borderRadius: BorderRadius.circular(DesignTokens.radius * scale),
      ),
      child: Wrap(
        spacing: 8 * scale,
        runSpacing: 8 * scale,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('已选 $selN 个文件夹', style: const TextStyle(fontSize: 13.5)),
          SizedBox(
            width: 220 * scale,
            child: _styledDropdown<String>(
              value: effectiveTargetId,
              items: [
                const DropdownMenuItem(
                  value: '__top__',
                  child: Text('移到顶层（成为一级文件夹）'),
                ),
                for (final f in tops)
                  DropdownMenuItem(value: f.id, child: Text('移到「${f.name}」下面')),
              ],
              onChanged: (v) => _update(() {
                if (v != null) _moveTargetId = v;
              }),
            ),
          ),
          QmButton(
            label: '移动',
            size: QmButtonSize.small,
            onPressed: selN > 0 ? _moveSelected : null,
          ),
          QmButton(
            label: '退出选择',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: () => _update(() {
              _selectingMove = false;
              _moveSelection.clear();
            }),
          ),
          Text(
            '移动时里面的题跟着一起走；不能移到自己下面；带子文件夹的一级文件夹不能再放进别的文件夹（只留一层）',
            style: TextStyle(fontSize: 12.5, color: palette.muted),
          ),
        ],
      ),
    );
  }

  /// 「全部题目」行（目录最上面一行；拖到它上面 = 移回顶层）。
  Widget _buildAllRow() {
    final subjectId = _subjectId!;
    // 与列表默认视图同口径（SR-P2-38 决定 (a)）：已掌握的题不计入。
    final total = _questions
        .where(
          (q) =>
              q.subjectId == subjectId &&
              q.isOrganized &&
              !q.isArchived &&
              !_isMastered(q),
        )
        .length;
    return DragTarget<Folder>(
      onWillAcceptWithDetails: (_) {
        _update(() => _dragOverKey = 'promote');
        return true;
      },
      onLeave: (_) => _update(() => _dragOverKey = null),
      onAcceptWithDetails: (d) {
        _update(() => _dragOverKey = null);
        _applyDrop(d.data, null, _DropKind.promote);
      },
      builder: (context, candidate, rejected) {
        final highlight = _dragOverKey == 'promote';
        return Container(
          decoration: highlight
              ? BoxDecoration(
                  border: Border.all(
                    color: DesignTokens.of(Theme.of(context).brightness).accent,
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(6),
                  color: DesignTokens.of(Theme.of(context).brightness).accent
                      .withValues(alpha: 0.08),
                )
              : null,
          child: _tocRowContent(
            name: '全部题目',
            count: total,
            strong: true,
            onTap: () => _openList(folderId: null),
          ),
        );
      },
    );
  }

  /// 两行之间的拖放缝隙（调顺序用；平时只有 10px 高的透明条）。
  /// SR2-28：文件夹搜索开着时缝隙下标按过滤后的可见列表算，
  /// `_reorderFolder` 却按全量列表解释，落点与所见不符——搜索有
  /// 关键词时缝隙一律拒收（拖到行上移进去仍可用），先搜后拖不移错。
  Widget _buildGapTarget(String? parentId, int index) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final key = 'gap:${parentId ?? 'top'}:$index';
    return DragTarget<Folder>(
      onWillAcceptWithDetails: (d) {
        if (_folderSearch.trim().isNotEmpty) return false;
        final dragged = d.data;
        if (dragged.parentId != parentId) return false;
        _update(() => _dragOverKey = key);
        return true;
      },
      onLeave: (_) => _update(() => _dragOverKey = null),
      onAcceptWithDetails: (d) {
        _update(() => _dragOverKey = null);
        _reorderFolder(d.data, parentId, index);
      },
      builder: (context, candidate, rejected) {
        final highlight = _dragOverKey == key;
        return Container(
          height: 10 * scale,
          decoration: BoxDecoration(
            border: highlight
                ? Border(top: BorderSide(color: palette.accent, width: 3))
                : null,
          ),
        );
      },
    );
  }

  Widget _buildKids(Folder parent, String kw, Set<String> effectiveExpanded) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final kids = _subFolders(parent.id)
        .where((s) => kw.isEmpty || s.name.toLowerCase().contains(kw))
        .toList();
    return Container(
      margin: EdgeInsets.only(left: DesignTokens.tocKidsIndent * scale),
      // Row 用 stretch 拉满虚线左缘时需要有限高度：包 IntrinsicHeight
      //（目录树很小，量测开销可忽略）。
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 子文件夹区左缘虚线（HTML `.nb-toc-kids`）。
            SizedBox(
              width: 2 * scale,
              child: CustomPaint(
                painter: _VerticalDashedPainter(color: palette.paperLine),
              ),
            ),
            Expanded(
              child: Column(
                children: [
                  for (var i = 0; i < kids.length; i++) ...[
                    _buildGapTarget(parent.id, i),
                    _buildFolderRow(kids[i], 1, effectiveExpanded),
                  ],
                  _buildGapTarget(parent.id, kids.length),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFolderRow(Folder f, int depth, Set<String> effectiveExpanded) {
    final isTop = depth == 0;
    final expanded = effectiveExpanded.contains(f.id);
    final kids = isTop ? _subFolders(f.id) : const <Folder>[];
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final rowKey = 'row:${f.id}';

    Widget rowContent;
    if (_renamingId == f.id) {
      rowContent = Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 36 * scale,
              child: TextField(
                controller: _renameCtrl,
                autofocus: true,
                decoration: const InputDecoration(isDense: true),
                onSubmitted: (_) => _saveRename(f),
              ),
            ),
          ),
          SizedBox(width: 8 * scale),
          _paperActionButton(label: '保存', onPressed: () => _saveRename(f)),
          SizedBox(width: 6 * scale),
          _paperActionButton(
            label: '取消',
            onPressed: () => _update(() => _renamingId = null),
          ),
        ],
      );
    } else {
      rowContent = Row(
        children: [
          if (isTop)
            SizedBox(
              width: DesignTokens.tocExpandWidth * scale,
              child: kids.isEmpty
                  ? const SizedBox.shrink()
                  : InkWell(
                      onTap: () => _update(() {
                        if (_expandedFolders.contains(f.id)) {
                          _expandedFolders.remove(f.id);
                        } else {
                          _expandedFolders.add(f.id);
                        }
                      }),
                      borderRadius: BorderRadius.circular(6 * scale),
                      child: Container(
                        constraints: BoxConstraints(
                          minHeight: DesignTokens.tocRowMinHeight * scale,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          expanded ? '▾' : '▸',
                          style: TextStyle(
                            fontSize: 14,
                            color: palette.paperMuted,
                          ),
                        ),
                      ),
                    ),
            ),
          if (_selectingMove)
            Checkbox(
              value: _moveSelection.contains(f.id),
              onChanged: (v) => _update(() {
                if (v == true) {
                  _moveSelection.add(f.id);
                } else {
                  _moveSelection.remove(f.id);
                }
              }),
            ),
          Expanded(
            child: _tocRowContent(
              name: f.name,
              count: _folderCount(f.id),
              sub: kids.isNotEmpty ? '${kids.length} 个子文件夹' : null,
              leftPadding: isTop ? 22 : 12,
              onTap: () {
                // 选择模式下点行 = 勾选 / 取消勾选（HTML bind）。
                if (_selectingMove) {
                  _update(() {
                    if (_moveSelection.contains(f.id)) {
                      _moveSelection.remove(f.id);
                    } else {
                      _moveSelection.add(f.id);
                    }
                  });
                } else {
                  _openList(folderId: f.id);
                }
              },
            ),
          ),
          Draggable<Folder>(
            data: f,
            onDragStarted: () => _update(() => _draggingId = f.id),
            onDragEnd: (_) => _update(() {
              _draggingId = null;
              _dragOverKey = null;
            }),
            feedback: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(8 * scale),
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 12 * scale,
                  vertical: 8 * scale,
                ),
                decoration: BoxDecoration(
                  color: palette.surface,
                  border: Border.all(color: palette.lineStrong),
                  borderRadius: BorderRadius.circular(8 * scale),
                ),
                child: Text(f.name),
              ),
            ),
            childWhenDragging: Opacity(
              opacity: 0.4,
              child: QmGlyph(
                QmGlyphs.drag,
                size: 15,
                color: palette.paperMuted,
              ),
            ),
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 8 * scale,
                  vertical: 8 * scale,
                ),
                child: QmGlyph(
                  QmGlyphs.drag,
                  size: 15,
                  color: palette.paperMuted,
                ),
              ),
            ),
          ),
          _paperActionButton(
            label: '改名',
            onPressed: () {
              _renameCtrl.text = f.name;
              _update(() => _renamingId = f.id);
            },
          ),
          SizedBox(width: 6 * scale),
          _paperActionButton(
            label: '删除',
            danger: true,
            onPressed: () => _askDeleteFolder(f),
          ),
        ],
      );
    }

    final body = Container(
      constraints: BoxConstraints(
        minHeight:
            (isTop
                ? DesignTokens.tocRowMinHeight
                : DesignTokens.tocChildRowMinHeight) *
            scale,
      ),
      padding: EdgeInsets.only(right: 4 * scale),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.paperLine)),
      ),
      child: rowContent,
    );

    // 拖到行上 = 移进去（拖到子文件夹行上时落在其父文件夹下面）。
    return DragTarget<Folder>(
      onWillAcceptWithDetails: (d) {
        if (d.data.id == f.id) return false;
        _update(() => _dragOverKey = rowKey);
        return true;
      },
      onLeave: (_) => _update(() => _dragOverKey = null),
      onAcceptWithDetails: (d) {
        _update(() => _dragOverKey = null);
        _applyDrop(d.data, f, _DropKind.into);
      },
      builder: (context, candidate, rejected) {
        final highlight = _dragOverKey == rowKey;
        final dragging = _draggingId == f.id;
        return Opacity(
          opacity: dragging ? 0.45 : 1,
          child: Container(
            decoration: highlight
                ? BoxDecoration(
                    border: Border.all(color: palette.accent, width: 2),
                    borderRadius: BorderRadius.circular(6),
                    color: palette.accent.withValues(alpha: 0.08),
                  )
                : null,
            child: body,
          ),
        );
      },
    );
  }

  /// 目录行主体（纸面上的行：名 + 子文件夹数 + 题数 + ›）。
  /// 左缩进：顶层行 /「全部题目」22px（HTML `.nb-toc-row`），
  /// 子文件夹行 12px（HTML `.nb-toc-kids .nb-toc-row`）。
  Widget _tocRowContent({
    required String name,
    required int count,
    String? sub,
    bool strong = false,
    double leftPadding = 22,
    required VoidCallback onTap,
  }) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6 * scale),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          leftPadding * scale,
          DesignTokens.tocRowPaddingV * scale,
          DesignTokens.tocRowPaddingH * scale,
          DesignTokens.tocRowPaddingV * scale,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  fontSize: DesignTokens.tocRowNameFontSize,
                  fontWeight: strong ? FontWeight.w800 : FontWeight.w700,
                  color: palette.paperInk,
                  height: DesignTokens.controlLineHeight,
                ),
              ),
            ),
            if (sub != null) ...[
              Text(
                sub,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: palette.paperMuted,
                ),
              ),
              SizedBox(width: 8 * scale),
            ],
            Text(
              '$count 道题',
              style: TextStyle(
                fontSize: DesignTokens.tocCountFontSize,
                fontWeight: FontWeight.w700,
                color: palette.paperMuted,
              ),
            ),
            SizedBox(width: 8 * scale),
            Text(
              '›',
              style: TextStyle(
                fontSize: 18,
                color: palette.paperMuted,
                height: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
