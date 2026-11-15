part of 'wrongbook_page.dart';

// 书内列表视图：列表页、工具条、筛选面板、批量条、大卡片 / 紧凑行 / 归档行、分页与已归档视图。

extension _WrongbookListBuild on _WrongbookPageState {
  Widget _buildList() {
    final all = _filteredAll();
    final totalPages = (all.length / _pageSize).ceil().clamp(1, 9999);
    final page = _page.clamp(0, totalPages - 1);
    final start = page * _pageSize;
    final items = all.skip(start).take(_pageSize).toList();
    final orderIds = all.map((q) => q.id).toList();
    final subject = _subjectId == null ? null : _subjectOf(_subjectId!);
    final folder = _folderId == null
        ? null
        : _folders.firstWhere(
            (f) => f.id == _folderId!,
            orElse: () =>
                Folder(id: _folderId!, name: '', subjectId: _subjectId ?? ''),
          );
    final title = _inBookArchived
        ? '${subject?.name ?? ''} · 错题本'
        : folder != null && folder.name.isNotEmpty
        ? subject != null
              ? '${subject.name} · ${folder.name}'
              : folder.name
        : subject != null
        ? '${subject.name} · 错题本'
        : '错题本';
    final scale = qmScaleOf(context);
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _pageTitle(title)),
              QmButton(
                label: '← 目录',
                variant: QmButtonVariant.plain,
                onPressed: () {
                  if (_subjectId != null) {
                    _openDirectory(_subjectId!);
                  } else {
                    _openShelf();
                  }
                },
              ),
              SizedBox(width: 8 * scale),
              QmButton(
                label: '合上 ✕',
                variant: QmButtonVariant.plain,
                onPressed: _openShelf,
              ),
            ],
          ),
          _pageSubtitle('这一科的题目列表，点一道题进题目详情；筛选里没有文件夹，文件夹在目录页选。'),
          _openBookFrame(
            subjectId: _subjectId ?? 'math',
            // 跨学科列表（无学科）时外框用中性灰，不回退数学蓝（SR-P2-54）。
            neutral: _subjectId == null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildListToolbar(),
                if (_filterOpen) _buildFilterPanel(),
                if (!_inBookArchived) _buildMasteredNote(),
                if (_inBookArchived) _buildArchBar(all.length),
                if (_batchMode && !_inBookArchived) _buildBatchBar(all),
                _paperBox(
                  cards:
                      _viewMode == 'large' &&
                      !_inBookArchived &&
                      items.isNotEmpty,
                  child: _inBookArchived
                      ? _buildArchivedRows(items, orderIds)
                      : items.isEmpty
                      ? _buildPaperEmpty()
                      : _viewMode == 'large'
                      ? _buildLargeCards(items, orderIds)
                      : _buildCompactRows(items, orderIds),
                ),
                if (all.isNotEmpty)
                  _buildPagination(all.length, totalPages, page),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildListToolbar() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final filterCount = _activeFilterCount();
    // HTML `.toolbar` 是 flex-wrap：窄窗 / 大字号时换行，不溢出。
    return Padding(
      padding: EdgeInsets.only(bottom: 12 * scale),
      child: Wrap(
        spacing: 8 * scale,
        runSpacing: 8 * scale,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 280 * scale,
            height: 40 * scale,
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: '按题名 / 文件夹 / 标签 / 学科 / 试卷 / 日期查找',
                hintStyle: TextStyle(color: palette.muted),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 13 * scale,
                  vertical: 9 * scale,
                ),
              ),
              onChanged: (v) => _update(() {
                _search = v;
                _page = 0;
              }),
            ),
          ),
          QmChip(
            label: filterCount > 0
                ? '筛选（已选 $filterCount）${_filterOpen ? ' ▴' : ' ▾'}'
                : '筛选${_filterOpen ? ' ▴' : ' ▾'}',
            selected: _filterOpen,
            onTap: () => _update(() => _filterOpen = !_filterOpen),
          ),
          QmChip(label: '重置', onTap: _resetFilters),
          SizedBox(
            width: 200 * scale,
            child: _styledDropdown<String>(
              value: _sort,
              items: const [
                DropdownMenuItem(value: 'new', child: Text('排序：时间 新 → 旧')),
                DropdownMenuItem(value: 'old', child: Text('排序：时间 旧 → 新')),
                DropdownMenuItem(
                  value: 'subj-asc',
                  child: Text('排序：学科首字母 A → Z'),
                ),
                DropdownMenuItem(
                  value: 'subj-desc',
                  child: Text('排序：学科首字母 Z → A'),
                ),
                DropdownMenuItem(
                  value: 'status-asc',
                  child: Text('排序：错因状态 待解决 → 已解决'),
                ),
                DropdownMenuItem(
                  value: 'status-desc',
                  child: Text('排序：错因状态 已解决 → 待解决'),
                ),
              ],
              onChanged: (v) => _update(() {
                if (v != null) {
                  _sort = v;
                  _page = 0;
                }
              }),
            ),
          ),
          QmChip(
            label: '大卡片',
            selected: _viewMode == 'large',
            onTap: () => _update(() => _viewMode = 'large'),
          ),
          QmChip(
            label: '紧凑列表',
            selected: _viewMode == 'compact',
            onTap: () => _update(() => _viewMode = 'compact'),
          ),
          if (!_inBookArchived)
            QmChip(
              label: '批量操作',
              selected: _batchMode,
              onTap: () => _update(() {
                _batchMode = !_batchMode;
                _selected.clear();
              }),
            ),
        ],
      ),
    );
  }

  Widget _buildFilterPanel() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final errorTypes = <String>{...ErrorTypes.fixed};
    for (final q in _questions) {
      errorTypes.addAll(q.allCauses);
    }
    Widget cell(String label, Widget control) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(bottom: 4 * scale),
            child: Text(
              label,
              style: TextStyle(
                fontSize: DesignTokens.filterCellLabelFontSize,
                fontWeight: FontWeight.w700,
                color: palette.muted,
              ),
            ),
          ),
          control,
        ],
      );
    }

    return Container(
      margin: EdgeInsets.only(bottom: 14 * scale),
      padding: EdgeInsets.symmetric(
        horizontal: DesignTokens.filterPanelPaddingH * scale,
        vertical: DesignTokens.filterPanelPaddingV * scale,
      ),
      decoration: BoxDecoration(
        color: palette.surface2,
        border: Border.all(color: palette.lineStrong),
        borderRadius: BorderRadius.circular(DesignTokens.radiusLg * scale),
      ),
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final cols = constraints.maxWidth > 700 ? 4 : 2;
              final rows = <Widget>[];
              final cells = [
                cell(
                  '试卷（来源）',
                  _styledDropdown<String>(
                    value: _filterExamId,
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('全部'),
                      ),
                      for (final e in _exams)
                        DropdownMenuItem(value: e.id, child: Text(e.name)),
                    ],
                    onChanged: (v) => _update(() {
                      _filterExamId = v;
                      _applyFilterChange(_filteredAll());
                    }),
                  ),
                ),
                cell(
                  '错误类型',
                  _styledDropdown<String>(
                    value: _filterErrorType,
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('全部'),
                      ),
                      for (final t in errorTypes)
                        DropdownMenuItem(value: t, child: Text(t)),
                    ],
                    onChanged: (v) => _update(() {
                      _filterErrorType = v;
                      _applyFilterChange(_filteredAll());
                    }),
                  ),
                ),
                cell(
                  '收集时间',
                  _styledDropdown<String>(
                    value: _filterTimeRange,
                    items: const [
                      DropdownMenuItem(value: 'all', child: Text('收集时间：全部')),
                      DropdownMenuItem(value: 'week', child: Text('最近一周')),
                      DropdownMenuItem(value: 'month', child: Text('最近一月')),
                    ],
                    onChanged: (v) => _update(() {
                      if (v != null) {
                        _filterTimeRange = v;
                        _applyFilterChange(_filteredAll());
                      }
                    }),
                  ),
                ),
                cell(
                  '错因状态',
                  _styledDropdown<String>(
                    value: _filterCauseStatus,
                    items: const [
                      DropdownMenuItem(value: 'all', child: Text('全部')),
                      DropdownMenuItem(value: 'pending', child: Text('待解决')),
                      DropdownMenuItem(value: 'inProgress', child: Text('解决中')),
                      DropdownMenuItem(value: 'solved', child: Text('已解决')),
                      DropdownMenuItem(value: 'recheck', child: Text('复查')),
                    ],
                    onChanged: (v) => _update(() {
                      if (v != null) {
                        _filterCauseStatus = v;
                        _applyFilterChange(_filteredAll());
                      }
                    }),
                  ),
                ),
              ];
              for (var i = 0; i < cells.length; i += cols) {
                rows.add(
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (
                        var j = i;
                        j < i + cols && j < cells.length;
                        j++
                      ) ...[
                        if (j > i) SizedBox(width: 14 * scale),
                        Expanded(child: cells[j]),
                      ],
                    ],
                  ),
                );
                if (i + cols < cells.length) {
                  rows.add(SizedBox(height: 10 * scale));
                }
              }
              return Column(children: rows);
            },
          ),
          SizedBox(height: 10 * scale),
          _filterOptionRow(
            label: '标签',
            children: [
              for (final t in _allTags)
                QmChip(
                  label: '#$t',
                  selected: _filterTags.contains(t),
                  onTap: () => _update(() {
                    if (_filterTags.contains(t)) {
                      _filterTags.remove(t);
                    } else {
                      _filterTags.add(t);
                    }
                    _applyFilterChange(_filteredAll());
                  }),
                ),
              for (final kpId in _filterKpIds)
                QmChip(
                  label:
                      '知识点：${_kps.firstWhere(
                        (k) => k.id == kpId,
                        orElse: () => const KnowledgePoint(id: '', subjectId: '', chapter: '', name: ''),
                      ).name}',
                  selected: true,
                  onDelete: () => _update(() {
                    _filterKpIds.remove(kpId);
                    _applyFilterChange(_filteredAll());
                  }),
                ),
              if (_filterCauseName != null)
                QmChip(
                  label: '错因：$_filterCauseName',
                  selected: true,
                  onDelete: () => _update(() {
                    _filterCauseName = null;
                    _applyFilterChange(_filteredAll());
                  }),
                ),
            ],
          ),
          _filterOptionRow(
            label: '只看',
            trailing: QmButton(
              label: '收起筛选',
              variant: QmButtonVariant.plain,
              size: QmButtonSize.small,
              onPressed: () => _update(() => _filterOpen = false),
            ),
            children: [
              QmChip(
                label: '仅收藏',
                selected: _filterFavorite,
                onTap: () => _update(() {
                  _filterFavorite = !_filterFavorite;
                  _applyFilterChange(_filteredAll());
                }),
              ),
              QmChip(
                label: '仅逾期',
                selected: _filterOverdue,
                onTap: () => _update(() {
                  _filterOverdue = !_filterOverdue;
                  _applyFilterChange(_filteredAll());
                }),
              ),
              QmChip(
                label: '已归档',
                selected: _inBookArchived,
                onTap: () => _update(() {
                  _inBookArchived = !_inBookArchived;
                  _page = 0;
                  _selected.clear();
                  _batchMode = false;
                }),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _filterOptionRow({
    required String label,
    required List<Widget> children,
    Widget? trailing,
  }) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Container(
      constraints: BoxConstraints(
        minHeight: DesignTokens.filterRowMinHeight * scale,
      ),
      padding: EdgeInsets.symmetric(vertical: 4 * scale),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: DesignTokens.filterRowLabelWidth * scale,
            child: Padding(
              padding: EdgeInsets.only(top: 7 * scale),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: palette.muted,
                  height: 1,
                ),
              ),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 8 * scale,
              runSpacing: 4 * scale,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: children,
            ),
          ),
          if (trailing != null) ...[SizedBox(width: 8 * scale), trailing],
        ],
      ),
    );
  }

  /// “错因全部已解决的题默认不显示”的提示（HTML `viewNotebook`）。
  /// 计数与当前列表范围同口径（SR-P2-38 决定 (a)）：在文件夹列表里
  /// 只数该文件夹子树里的已掌握题，不再用整科数。
  Widget _buildMasteredNote() {
    if (_filterCauseStatus == 'solved') return const SizedBox.shrink();
    final folderIds = _folderId == null ? null : _subtreeIds(_folderId!);
    final hidden = _questions
        .where(
          (q) =>
              q.isOrganized &&
              !q.isArchived &&
              (_subjectId == null || q.subjectId == _subjectId) &&
              (folderIds == null ||
                  q.folderIds.any((id) => folderIds.contains(id))) &&
              _isMastered(q),
        )
        .length;
    if (hidden == 0) return const SizedBox.shrink();
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scope = _folderId != null
        ? '这个文件夹里'
        : (_subjectId == null ? '' : '这科');
    return Padding(
      padding: EdgeInsets.only(bottom: 10 * scale),
      child: Text(
        '$scope错因已全部解决 $hidden 道默认不显示（在「筛选」里把错因状态选成「已解决」可看）',
        style: TextStyle(fontSize: 12.5, color: palette.muted),
      ),
    );
  }

  Widget _buildArchBar(int count) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Container(
      margin: EdgeInsets.only(bottom: 12 * scale),
      padding: EdgeInsets.symmetric(
        horizontal: 14 * scale,
        vertical: 10 * scale,
      ),
      decoration: BoxDecoration(
        color: palette.surface2,
        border: Border.all(color: palette.line),
        borderRadius: BorderRadius.circular(DesignTokens.radius * scale),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '已归档 · 共 $count 道 — 归档的题不在题目列表里，在这里能找回、能恢复',
              style: const TextStyle(fontSize: 14),
            ),
          ),
          QmButton(
            label: '← 返回题目列表',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: () => _update(() {
              _inBookArchived = false;
              _page = 0;
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildBatchBar(List<Question> all) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final selInList = all.where((q) => _selected.contains(q.id)).length;
    final allChecked = all.isNotEmpty && selInList == all.length;
    final someChecked = selInList > 0 && selInList < all.length;
    final options = _batchFolderOptions();
    // 下拉的当前值必须在选项里：存量值失效（文件夹被删）时回落到首项，
    // 不在 build 里写回状态。
    final batchFolderId = options.any((f) => f.id == _batchFolderId)
        ? _batchFolderId
        : (options.isNotEmpty ? options.first.id : null);
    final hasSelection = _selected.isNotEmpty;
    return Container(
      margin: EdgeInsets.only(bottom: 12 * scale),
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
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                tristate: true,
                value: allChecked ? true : (someChecked ? null : false),
                onChanged: (_) => _toggleSelectAll(all),
              ),
              GestureDetector(
                onTap: () => _toggleSelectAll(all),
                child: const Text(
                  '全选当前结果',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          Text(
            '已选 ${_selected.length} 道',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          // 跨学科列表（错因/知识点筛选进来）没有归属学科，批量移
          // 文件夹的目标下拉是空的（SR-P2-41）：进批量模式就说明，
          // 别等用户点了才发现移不了。
          if (_subjectId == null)
            Text(
              '跨学科列表不能批量移文件夹：先打开一本书，再批量移',
              style: TextStyle(fontSize: 12.5, color: palette.muted),
            ),
          QmButton(
            label: '批量加标签',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: hasSelection ? _batchAddTag : null,
          ),
          if (options.isNotEmpty)
            SizedBox(
              width: 200 * scale,
              child: _styledDropdown<String>(
                value: batchFolderId,
                items: [
                  for (final f in options)
                    DropdownMenuItem(value: f.id, child: Text(_folderLabel(f))),
                ],
                onChanged: (v) => _update(() {
                  if (v != null) _batchFolderId = v;
                }),
              ),
            ),
          QmButton(
            label: _folderId != null ? '批量移入文件夹' : '批量加入文件夹',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: hasSelection && options.isNotEmpty
                ? () => _batchMoveToFolder(batchFolderId)
                : null,
          ),
          if (_folderId != null)
            QmButton(
              label: '批量移出当前文件夹',
              variant: QmButtonVariant.plain,
              size: QmButtonSize.small,
              onPressed: hasSelection ? _batchMoveOut : null,
            ),
          QmButton(
            label: '批量收藏',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: hasSelection ? _batchFavorite : null,
          ),
          QmButton(
            label: '批量归档',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: hasSelection ? _batchArchive : null,
          ),
          QmButton(
            label: '批量删除',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: hasSelection ? _askBatchDelete : null,
          ),
          QmButton(
            label: '清除选择',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: hasSelection
                ? () => _update(() {
                    _selected.clear();
                  })
                : null,
          ),
          QmButton(
            label: '退出批量',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: () => _update(() {
              _batchMode = false;
              _selected.clear();
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildPaperEmpty() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 12 * scale,
        vertical: 28 * scale,
      ),
      child: Column(
        children: [
          Text(
            _inBookArchived ? '这一本里还没有归档的题' : '没找到这道题，换个词试试',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: palette.paperInk,
            ),
          ),
          SizedBox(height: 4 * scale),
          Text(
            _inBookArchived ? '归档的题会放在这里，随时能恢复回错题本。' : '这一科里没有符合当前搜索与筛选的题。',
            style: TextStyle(fontSize: 13.5, color: palette.paperMuted),
          ),
          SizedBox(height: 12 * scale),
          QmButton(
            label: _inBookArchived ? '返回题目列表' : '清除全部筛选',
            size: QmButtonSize.small,
            onPressed: () {
              if (_inBookArchived) {
                _update(() => _inBookArchived = false);
              } else {
                _resetFilters();
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildLargeCards(List<Question> items, List<String> orderIds) {
    final scale = qmScaleOf(context);
    final gap = DesignTokens.cardsGap * scale;
    final cards = <Widget>[
      for (var i = 0; i < items.length; i++)
        // 序号 = 本页内的位置（1, 2, 3…），随排序 / 筛选 / 分页重编号。
        _buildLargeCard(items[i], i + 1, orderIds),
    ];
    if (items.length > 2) {
      // >2 张卡：固定高度内部滚动容器（约 2.5 张卡，第三张露一半）。
      final palette = DesignTokens.of(Theme.of(context).brightness);
      return Container(
        height: DesignTokens.cardsScrollHeight * scale,
        padding: EdgeInsets.all(DesignTokens.cardsScrollPadding * scale),
        decoration: BoxDecoration(
          border: Border.all(color: palette.lineStrong),
          borderRadius: BorderRadius.circular(DesignTokens.radius * scale),
        ),
        child: ListView.separated(
          itemCount: cards.length,
          separatorBuilder: (_, __) => SizedBox(height: gap),
          itemBuilder: (context, i) => cards[i],
        ),
      );
    }
    return Column(
      children: [
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          cards[i],
        ],
      ],
    );
  }

  /// 大卡片一题一行：卡片本身就是整题切片（外层无背景 / 无边框 /
  /// 无阴影 / 无内边距；切片白底 + 细边框，封顶 160px、按比例缩放
  /// 绝不裁切）；左上角蓝色序号圆盘；卡片上不显示题名 / 学科 /
  /// 错误类型 / 标签 / 下次复习时间 / 收藏星。
  Widget _buildLargeCard(Question q, int number, List<String> orderIds) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Stack(
      children: [
        QuestionSlice(
          question: q,
          subject: _subjectOf(q.subjectId),
          maxHeight: 160 * scale,
          fixedHeight: true,
          onTap: () async {
            await widget.onOpenDetail(q, orderIds);
            await _load();
          },
        ),
        Positioned(
          top: 7 * scale,
          left: 7 * scale,
          child: IgnorePointer(
            child: Container(
              constraints: BoxConstraints(
                minWidth: DesignTokens.seqBadgeSize * scale,
              ),
              height: DesignTokens.seqBadgeSize * scale,
              padding: EdgeInsets.symmetric(horizontal: 7 * scale),
              decoration: BoxDecoration(
                color: palette.accent,
                borderRadius: BorderRadius.circular(999 * scale),
                border: Border.all(color: palette.surface, width: 2 * scale),
                boxShadow: const [
                  BoxShadow(
                    offset: Offset(0, 2),
                    blurRadius: 6,
                    color: Color.fromRGBO(23, 35, 59, 0.28),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: Text(
                '$number',
                style: TextStyle(
                  fontSize: DesignTokens.seqBadgeFontSize,
                  fontWeight: FontWeight.w800,
                  color: palette.accentInk,
                  height: 1,
                ),
              ),
            ),
          ),
        ),
        if (_batchMode)
          Positioned(
            top: 9 * scale,
            left: DesignTokens.cardCheckLeft * scale,
            child: Container(
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(5 * scale),
              ),
              child: Checkbox(
                value: _selected.contains(q.id),
                onChanged: (v) => _update(() {
                  if (v == true) {
                    _selected.add(q.id);
                  } else {
                    _selected.remove(q.id);
                  }
                }),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCompactRows(List<Question> items, List<String> orderIds) {
    final scale = qmScaleOf(context);
    return Column(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) QmRowLine(kind: QmRowLineKind.paper),
          _buildCompactRow(items[i], orderIds),
        ],
        SizedBox(height: 4 * scale),
      ],
    );
  }

  Widget _buildCompactRow(Question q, List<String> orderIds) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final nextRecheck = _nextRecheckOf(q);
    return InkWell(
      onTap: () async {
        await widget.onOpenDetail(q, orderIds);
        await _load();
      },
      borderRadius: BorderRadius.circular(6 * scale),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          DesignTokens.prowPaddingLeft * scale,
          DesignTokens.prowPaddingV * scale,
          DesignTokens.prowPaddingH * scale,
          DesignTokens.prowPaddingV * scale,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_batchMode)
              Padding(
                padding: EdgeInsets.only(right: 8 * scale),
                child: Checkbox(
                  value: _selected.contains(q.id),
                  onChanged: (v) => _update(() {
                    if (v == true) {
                      _selected.add(q.id);
                    } else {
                      _selected.remove(q.id);
                    }
                  }),
                ),
              ),
            GestureDetector(
              onTap: () => showQuestionZoomDialog(context, q),
              child: CompactSliceThumb(
                question: q,
                subject: _subjectOf(q.subjectId),
              ),
            ),
            SizedBox(width: 12 * scale),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    q.title,
                    style: TextStyle(
                      fontSize: DesignTokens.prowTitleFontSize,
                      fontWeight: FontWeight.w700,
                      color: palette.paperInk,
                    ),
                  ),
                  SizedBox(height: 2 * scale),
                  _prowMetaLine(q),
                  SizedBox(height: 4 * scale),
                  Wrap(
                    spacing: 6 * scale,
                    runSpacing: 4 * scale,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final (cause, status) in _causeStatusesOf(q))
                        _causePill(cause, status),
                      Text(
                        '下次复查 ${nextRecheck == null ? '—' : '${nextRecheck.month}月${nextRecheck.day}日'}',
                        style: TextStyle(
                          fontSize: DesignTokens.prowDetailFontSize,
                          color: palette.paperMuted,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(width: 8 * scale),
            _PaperStarButton(
              favorite: q.isFavorite,
              onPressed: () => _toggleFavorite(q),
            ),
            SizedBox(width: 4 * scale),
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

  /// 紧凑行 / 归档行明细行（HTML `.nb-prow .d`）：学科名着学科色
  ///（纸面取浅色档），其余取纸面次级色。学科取库里的 `_subjects`
  ///（B2 补充；以前 `Subject.byId` 未知 id 回退到数学名 +
  /// `subjectInk` 不传存色落到数学色）。
  Widget _prowMetaLine(Question q) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final subject = _subjects.firstWhere(
      (s) => s.id == q.subjectId,
      orElse: () => Subject.byId(q.subjectId),
    );
    final subjectInk = DesignTokens.subjectInk(
      q.subjectId,
      Brightness.light,
      subject.color,
    );
    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: TextStyle(
          fontSize: DesignTokens.prowDetailFontSize,
          color: palette.paperMuted,
        ),
        children: [
          TextSpan(
            text: subject.name,
            style: TextStyle(color: subjectInk),
          ),
          TextSpan(
            text:
                ' · 错误类型：${q.allCauses.isEmpty ? '—' : q.allCauses.join('、')} · 标签：${q.tags.isEmpty ? '—' : q.tags.join('、')}',
          ),
        ],
      ),
    );
  }

  /// 紧凑行里的错因 pill：「错因·状态」，颜色与错因四态一致。
  Widget _causePill(String cause, String status) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final (bg, fg) = switch (status) {
      'pending' => (palette.warnBg, palette.warnInk),
      'inProgress' => (palette.infoBg, palette.infoInk),
      'solved' => (palette.accentSoft, palette.accentText),
      _ => (palette.errBg, palette.errInk),
    };
    final label = switch (status) {
      'pending' => '待解决',
      'inProgress' => '解决中',
      'solved' => '已解决',
      _ => '复查',
    };
    return QmStatusPill(label: '$cause·$label', background: bg, foreground: fg);
  }

  Widget _buildArchivedRows(List<Question> items, List<String> orderIds) {
    final scale = qmScaleOf(context);
    return Column(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) QmRowLine(kind: QmRowLineKind.paper),
          _buildArchivedRow(items[i], orderIds),
        ],
        SizedBox(height: 4 * scale),
      ],
    );
  }

  Widget _buildArchivedRow(Question q, List<String> orderIds) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return InkWell(
      onTap: () async {
        await widget.onOpenDetail(q, orderIds);
        await _load();
      },
      borderRadius: BorderRadius.circular(6 * scale),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          DesignTokens.prowPaddingLeft * scale,
          DesignTokens.prowPaddingV * scale,
          DesignTokens.prowPaddingH * scale,
          DesignTokens.prowPaddingV * scale,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => showQuestionZoomDialog(context, q),
              child: CompactSliceThumb(
                question: q,
                subject: _subjectOf(q.subjectId),
              ),
            ),
            SizedBox(width: 12 * scale),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          q.title,
                          style: TextStyle(
                            fontSize: DesignTokens.prowTitleFontSize,
                            fontWeight: FontWeight.w700,
                            color: palette.paperInk,
                          ),
                        ),
                      ),
                      SizedBox(width: 8 * scale),
                      QmStatusPill.tone(label: '已归档', tone: QmTone.warn),
                    ],
                  ),
                  SizedBox(height: 2 * scale),
                  _prowMetaLine(q),
                ],
              ),
            ),
            SizedBox(width: 8 * scale),
            QmButton(
              label: '恢复到错题本',
              variant: QmButtonVariant.plain,
              size: QmButtonSize.small,
              onPressed: () => _restoreArchived(q),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPagination(int total, int totalPages, int page) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Container(
      margin: EdgeInsets.only(top: DesignTokens.pagerMarginTop * scale),
      padding: EdgeInsets.only(top: DesignTokens.pagerPaddingTop * scale),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.line)),
      ),
      child: Row(
        children: [
          Text(
            '共 $total 道 · 第 ${page + 1} / $totalPages 页',
            style: TextStyle(
              fontSize: DesignTokens.pagerFontSize,
              color: palette.muted,
            ),
          ),
          SizedBox(width: 10 * scale),
          const Text('每页', style: TextStyle(fontSize: 13.5)),
          SizedBox(width: 4 * scale),
          SizedBox(
            width: 76 * scale,
            child: _styledDropdown<int>(
              value: _pageSize,
              items: [10, 20, 30, 40, 50]
                  .map((n) => DropdownMenuItem(value: n, child: Text('$n')))
                  .toList(),
              onChanged: (v) => _update(() {
                if (v != null) {
                  _pageSize = v;
                  _page = 0;
                }
              }),
            ),
          ),
          SizedBox(width: 4 * scale),
          const Text('道', style: TextStyle(fontSize: 13.5)),
          const Spacer(),
          QmButton(
            label: '上一页',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: page > 0 ? () => _update(() => _page = page - 1) : null,
          ),
          SizedBox(width: 6 * scale),
          if (totalPages > 1)
            for (var i = 0; i < totalPages; i++) ...[
              if (i > 0) SizedBox(width: 6 * scale),
              _pageNumButton(
                i + 1,
                selected: i == page,
                onTap: () {
                  _update(() => _page = i);
                },
              ),
            ],
          if (totalPages > 1) SizedBox(width: 6 * scale),
          QmButton(
            label: '下一页',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: page < totalPages - 1
                ? () => _update(() => _page = page + 1)
                : null,
          ),
        ],
      ),
    );
  }

  // ----- 已归档（书架顶部入口，跨学科） -----

  Widget _buildArchived() {
    final archived = _questions.where((q) => q.isArchived).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final orderIds = archived.map((q) => q.id).toList();
    // 跨学科已归档视图也分页（SR-P2-46，与书内列表同一分页器，
    // 默认 10 条）：归档是只增不减的冷数据，全量渲染会越拖越长。
    // 搜索暂缓（先补分页）。
    final totalPages = (archived.length / _pageSize).ceil().clamp(1, 9999);
    final page = _page.clamp(0, totalPages - 1);
    final items = archived.skip(page * _pageSize).take(_pageSize).toList();
    final scale = qmScaleOf(context);
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _pageTitle('已归档')),
              QmButton(
                label: '← 返回书架',
                variant: QmButtonVariant.plain,
                onPressed: _openShelf,
              ),
            ],
          ),
          SizedBox(height: 6 * scale),
          Text(
            '${archived.length} 道题',
            style: TextStyle(
              fontSize: 13.5,
              color: DesignTokens.of(Theme.of(context).brightness).muted,
            ),
          ),
          SizedBox(height: 14 * scale),
          if (archived.isEmpty)
            QmEmptyState(
              title: '还没有归档的题',
              description: '在打开的书里批量归档、或在题目详情里归档的题，会放在这里，随时能恢复回错题本。',
            )
          else ...[
            _paperBox(child: _buildArchivedRows(items, orderIds)),
            _buildPagination(archived.length, totalPages, page),
          ],
        ],
      ),
    );
  }
}
