part of 'wrongbook_page.dart';

// B8-9：题目列表样式（Meng 2026-11-15 定稿 A 留白卡片）：
// 大卡片各成一张白卡，紧凑行 / 归档行共用一张白卡；
// B 纸面通栏、C 极简线条已废弃，截图留档在
// docs/ui-replication/shots/b8-list/after-B-*.png、after-C-*.png。

// 书内列表视图：列表页、工具条、筛选面板、批量条、大卡片 / 紧凑行 / 归档行、分页与已归档视图。

extension _WrongbookListBuild on _WrongbookViewState {
  Widget _buildList() {
    final all = _s.filteredAll();
    final totalPages = (all.length / _s.pageSize).ceil().clamp(1, 9999);
    final page = _s.page.clamp(0, totalPages - 1);
    final start = page * _s.pageSize;
    final items = all.skip(start).take(_s.pageSize).toList();
    final orderIds = all.map((q) => q.id).toList();
    final subject = _s.subjectId == null ? null : _s.subjectOf(_s.subjectId!);
    final folder = _s.folderId == null
        ? null
        : _s.folders.firstWhere(
            (f) => f.id == _s.folderId!,
            orElse: () => Folder(
              id: _s.folderId!,
              name: '',
              subjectId: _s.subjectId ?? '',
            ),
          );
    final title = _s.inBookArchived
        // FR-17：无学科时不留悬空的“ · ”，与下面分支同款处理。
        ? subject != null
              ? '${subject.name} · 错题本'
              : '已归档 · 错题本'
        : folder != null && folder.name.isNotEmpty
        ? subject != null
              ? '${subject.name} · ${folder.name}'
              : folder.name
        : subject != null
        ? '${subject.name} · 错题本'
        : '错题本';
    final scale = qmScaleOf(context);
    // B8-9：去掉蓝色大框（_openBookFrame）：工具条 / 筛选 / 列表 / 分页
    // 直接落在页面底色上，列表本体按定稿 A 留白卡片排版。
    // 目录页的书框不动（那是目录页的样式，不在本次范围）。
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
                  if (_sr.subjectId != null) {
                    _openDirectory(_sr.subjectId!);
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
          _buildListToolbar(),
          if (_s.filterOpen) _buildFilterPanel(),
          if (!_s.inBookArchived) _buildMasteredNote(),
          if (_s.inBookArchived) _buildArchBar(all.length),
          if (_s.batchMode && !_s.inBookArchived) _buildBatchBar(all),
          _buildListBody(items, orderIds),
          if (all.isNotEmpty) _buildPagination(all.length, totalPages, page),
          // B8-9：页尾留白——分页器是页内最后一个元素，滚到底时它贴着
          // 视口底边；此时点“每页 N 道”下拉，框架按选中项对齐按钮中心
          // 会把菜单底推出视口（debug 下触发 dropdown.dart 的
          // menuLimits 断言；release 下菜单底被裁 5px）。留 24px，
          // 按钮离底边够远、菜单放得下，视觉上页尾也不挤。
          SizedBox(height: 24 * scale),
        ],
      ),
    );
  }

  /// 列表本体（含空状态）：A 留白卡片——大卡片自带单卡容器，
  /// 紧凑行 / 归档行共用一张白卡。
  Widget _buildListBody(List<Question> items, List<String> orderIds) {
    if (items.isEmpty) return _buildListEmpty();
    if (_s.inBookArchived) {
      return _listSurface(child: _buildArchivedRows(items, orderIds));
    }
    if (_s.viewMode == 'large') return _buildLargeCards(items, orderIds);
    return _listSurface(child: _buildCompactRows(items, orderIds));
  }

  /// 白卡容器（紧凑行 / 归档行共用一张卡）。
  Widget _listSurface({required Widget child}) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8 * scale, vertical: 4 * scale),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border.all(color: palette.line),
        borderRadius: BorderRadius.circular(DesignTokens.radius * scale),
        boxShadow: palette.shadow,
      ),
      child: child,
    );
  }

  /// 空状态文案三分法（B8-9 必修）：
  /// - 已归档视图空 → 归档文案（旧文案不动）；
  /// - 范围本身没题（文件夹 / 学科是空的）→ 文件夹为空文案 + 去收集 /
  ///   去整理的引导，不再冒充搜索无结果；
  /// - 范围有题、但无搜索无筛选还为空 → 只剩“全部已解决被默认隐藏”这
  ///   一种可能，给看已解决的入口；
  /// - 其余（搜不到 / 筛不到）→ 搜索无结果文案（旧文案不动）。
  ///
  /// D-32（Meng 2026-11-16 定：改按钮不改文案）：范围为空时，
  /// `onGoCollect` / `onGoOrganize` 都接通时动作位是“去收集”
  ///（主按钮，进 /collect）+“去整理”（次按钮，进 /organize）；
  /// 任一回调未接通（如测试里没传）时回落到旧的单按钮
  /// “返回目录 / 返回书架”。页头已有“← 目录 / 合上 ✕”，
  /// 返回入口不丢。
  ({
    String title,
    String desc,
    String action,
    VoidCallback onAction,
    String? secondaryAction,
    VoidCallback? onSecondaryAction,
  })
  _emptyCopy() {
    if (_s.inBookArchived) {
      return (
        title: '这一本里还没有归档的题',
        desc: '归档的题会放在这里，随时能恢复回错题本。',
        action: '返回题目列表',
        onAction: () => _n.update((st) => st.copyWith(inBookArchived: false)),
        secondaryAction: null,
        onSecondaryAction: null,
      );
    }
    if (_s.scopeQuestionCount() == 0) {
      final back = _s.folderId != null || _s.subjectId != null
          ? (
              label: '返回目录',
              go: () {
                if (_sr.subjectId != null) {
                  _openDirectory(_sr.subjectId!);
                } else {
                  _openShelf();
                }
              },
            )
          : (label: '返回书架', go: _openShelf);
      // D-32：双入口齐全时用“去收集 / 去整理”替代返回按钮。
      final collectGo =
          widget.onGoCollect != null && widget.onGoOrganize != null
          ? (
              action: '去收集',
              onAction: widget.onGoCollect!,
              secondaryAction: '去整理',
              onSecondaryAction: widget.onGoOrganize!,
            )
          : null;
      if (_s.folderId != null) {
        return (
          title: '这个文件夹还是空的',
          desc: '这里还没有整理进来的题。去收集中心拍一道题，或去整理工作台把待整理的题归到这个文件夹。',
          action: collectGo?.action ?? back.label,
          onAction: collectGo?.onAction ?? back.go,
          secondaryAction: collectGo?.secondaryAction,
          onSecondaryAction: collectGo?.onSecondaryAction,
        );
      }
      if (_s.subjectId != null) {
        return (
          title: '这科里还没有错题',
          desc: '这科里还没有整理进来的题。去收集中心拍一道题，或去整理工作台把待整理的题归进来。',
          action: collectGo?.action ?? back.label,
          onAction: collectGo?.onAction ?? back.go,
          secondaryAction: collectGo?.secondaryAction,
          onSecondaryAction: collectGo?.onSecondaryAction,
        );
      }
      return (
        title: '错题本里还没有题',
        desc: '去收集中心拍第一道题吧。',
        action: collectGo?.action ?? back.label,
        onAction: collectGo?.onAction ?? back.go,
        secondaryAction: collectGo?.secondaryAction,
        onSecondaryAction: collectGo?.onSecondaryAction,
      );
    }
    if (!_s.hasSearchOrFilter()) {
      return (
        title: '这里的题错因都已解决',
        desc: '错因全部解决的题默认不显示，在「筛选」里把错因状态选成「已解决」就能看到它们。',
        action: '看看已解决的题',
        onAction: () => _n.update(
          (st) => st.copyWith(filterCauseStatus: 'solved', page: 0),
        ),
        secondaryAction: null,
        onSecondaryAction: null,
      );
    }
    return (
      title: '没找到这道题，换个词试试',
      desc: '这一科里没有符合当前搜索与筛选的题。',
      action: '清除全部筛选',
      onAction: _resetFilters,
      secondaryAction: null,
      onSecondaryAction: null,
    );
  }

  /// 空状态本体：A 留白卡片——虚线框 + 小伙伴（QmEmptyState）。
  Widget _buildListEmpty() {
    final copy = _emptyCopy();
    return QmEmptyState(
      title: copy.title,
      description: copy.desc,
      actionLabel: copy.action,
      onAction: copy.onAction,
      secondaryActionLabel: copy.secondaryAction,
      onSecondaryAction: copy.onSecondaryAction,
    );
  }

  Widget _buildListToolbar() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final filterCount = _s.activeFilterCount();
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
              onChanged: (v) => _n.setSearch(v),
            ),
          ),
          QmChip(
            label: filterCount > 0
                ? '筛选（已选 $filterCount）${_s.filterOpen ? ' ▴' : ' ▾'}'
                : '筛选${_s.filterOpen ? ' ▴' : ' ▾'}',
            selected: _s.filterOpen,
            onTap: () =>
                _n.update((st) => st.copyWith(filterOpen: !st.filterOpen)),
          ),
          QmChip(label: '重置', onTap: _resetFilters),
          SizedBox(
            width: 200 * scale,
            child: _styledDropdown<String>(
              value: _s.sort,
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
              onChanged: (v) {
                if (v != null) _n.setSort(v);
              },
            ),
          ),
          QmChip(
            label: '大卡片',
            selected: _s.viewMode == 'large',
            onTap: () => _n.setViewMode('large'),
          ),
          QmChip(
            label: '紧凑列表',
            selected: _s.viewMode == 'compact',
            onTap: () => _n.setViewMode('compact'),
          ),
          if (!_s.inBookArchived)
            QmChip(
              label: '批量操作',
              selected: _s.batchMode,
              onTap: () => _n.update(
                (st) => st.copyWith(
                  batchMode: !st.batchMode,
                  selected: const <String>{},
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFilterPanel() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final errorTypes = <String>{...ErrorTypes.fixed};
    for (final q in _s.questions) {
      errorTypes.addAll(q.allCauses);
    }
    // SR2-34：与批量条同款防线——_s.filterErrorType 可能在详情页删题后
    // 失效（唯一带某自定义错因的题被删），不在 build 里写回状态；
    // _load 里另有复位（见 wrongbook_page.dart _load），这里兜住
    // _load 之前 / 之外的重建。
    final effectiveErrorType =
        _s.filterErrorType != null && errorTypes.contains(_s.filterErrorType)
        ? _s.filterErrorType
        : null;
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
                    value: _s.filterExamId,
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('全部'),
                      ),
                      for (final e in _s.exams)
                        DropdownMenuItem(value: e.id, child: Text(e.name)),
                    ],
                    onChanged: (v) => _n.setFilterExamId(v),
                  ),
                ),
                cell(
                  '错误类型',
                  _styledDropdown<String>(
                    value: effectiveErrorType,
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('全部'),
                      ),
                      for (final t in errorTypes)
                        DropdownMenuItem(value: t, child: Text(t)),
                    ],
                    onChanged: (v) => _n.setFilterErrorType(v),
                  ),
                ),
                cell(
                  '收集时间',
                  _styledDropdown<String>(
                    value: _s.filterTimeRange,
                    items: const [
                      DropdownMenuItem(value: 'all', child: Text('收集时间：全部')),
                      DropdownMenuItem(value: 'week', child: Text('最近一周')),
                      DropdownMenuItem(value: 'month', child: Text('最近 30 天')),
                    ],
                    onChanged: (v) {
                      if (v != null) _n.setFilterTimeRange(v);
                    },
                  ),
                ),
                cell(
                  '错因状态',
                  _styledDropdown<String>(
                    value: _s.filterCauseStatus,
                    items: const [
                      DropdownMenuItem(value: 'all', child: Text('全部')),
                      DropdownMenuItem(value: 'pending', child: Text('待解决')),
                      DropdownMenuItem(value: 'inProgress', child: Text('解决中')),
                      DropdownMenuItem(value: 'solved', child: Text('已解决')),
                      DropdownMenuItem(value: 'recheck', child: Text('复查')),
                    ],
                    onChanged: (v) {
                      if (v != null) _n.setFilterCauseStatus(v);
                    },
                  ),
                ),
                // 十四批 M1：题型筛选（全部 + 待确认 + 17 个类型；
                // 待确认筛 questionType == null，见 notifier 的 '' 口径）。
                // 放面板末尾：既有测试按序号点下拉（.at(3) 收集时间、
                // .at(4) 错因状态），插中间会移位，末尾不影响。
                cell(
                  '题型',
                  _styledDropdown<String>(
                    value: _s.filterQuestionType,
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('全部'),
                      ),
                      const DropdownMenuItem<String>(
                        value: '',
                        child: Text('待确认'),
                      ),
                      for (final v in questionTypeValues)
                        DropdownMenuItem(
                          value: v,
                          child: Text(questionTypeLabels[v]!),
                        ),
                    ],
                    onChanged: (v) => _n.setFilterQuestionType(v),
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
              for (final t in _s.allTags)
                QmChip(
                  label: '#$t',
                  selected: _s.filterTags.contains(t),
                  onTap: () => _n.toggleFilterTag(t),
                ),
              for (final kpId in _s.filterKpIds)
                QmChip(
                  label:
                      '知识点：${_s.kps.firstWhere(
                        (k) => k.id == kpId,
                        orElse: () => const KnowledgePoint(id: '', subjectId: '', chapter: '', name: ''),
                      ).name}',
                  selected: true,
                  onDelete: () => _n.removeFilterKpId(kpId),
                ),
              if (_s.filterCauseName != null)
                QmChip(
                  label: '错因：$_s.filterCauseName',
                  selected: true,
                  onDelete: () => _n.clearFilterCauseName(),
                ),
            ],
          ),
          _filterOptionRow(
            label: '只看',
            trailing: QmButton(
              label: '收起筛选',
              variant: QmButtonVariant.plain,
              size: QmButtonSize.small,
              onPressed: () =>
                  _n.update((st) => st.copyWith(filterOpen: false)),
            ),
            children: [
              QmChip(
                label: '仅收藏',
                selected: _s.filterFavorite,
                onTap: () => _n.toggleFilterFavorite(),
              ),
              QmChip(
                label: '仅逾期',
                selected: _s.filterOverdue,
                onTap: () => _n.toggleFilterOverdue(),
              ),
              QmChip(
                label: '已归档',
                selected: _s.inBookArchived,
                onTap: () => _n.toggleInBookArchived(),
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
    if (_s.filterCauseStatus == 'solved') return const SizedBox.shrink();
    final folderIds = _s.folderId == null ? null : _s.subtreeIds(_s.folderId!);
    final hidden = _s.questions
        .where(
          (q) =>
              q.isOrganized &&
              !q.isArchived &&
              (_s.subjectId == null || q.subjectId == _s.subjectId) &&
              (folderIds == null ||
                  q.folderIds.any((id) => folderIds.contains(id))) &&
              _s.isMastered(q),
        )
        .length;
    if (hidden == 0) return const SizedBox.shrink();
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scope = _s.folderId != null
        ? '这个文件夹里'
        : (_s.subjectId == null ? '' : '这科');
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
            onPressed: () =>
                _n.update((st) => st.copyWith(inBookArchived: false, page: 0)),
          ),
        ],
      ),
    );
  }

  Widget _buildBatchBar(List<Question> all) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final selInList = all.where((q) => _s.selected.contains(q.id)).length;
    final allChecked = all.isNotEmpty && selInList == all.length;
    final someChecked = selInList > 0 && selInList < all.length;
    final options = _s.batchFolderOptions();
    // 下拉的当前值必须在选项里：存量值失效（文件夹被删）时回落到首项，
    // 不在 build 里写回状态。
    final batchFolderId = options.any((f) => f.id == _s.batchFolderId)
        ? _s.batchFolderId
        : (options.isNotEmpty ? options.first.id : null);
    final hasSelection = _s.selected.isNotEmpty;
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
            '已选 ${_s.selected.length} 道',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          // 跨学科列表（错因/知识点筛选进来）没有归属学科，批量移
          // 文件夹的目标下拉是空的（SR-P2-41）：进批量模式就说明，
          // 别等用户点了才发现移不了。
          if (_s.subjectId == null)
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
                    DropdownMenuItem(
                      value: f.id,
                      child: Text(_s.folderLabel(f)),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) {
                    _n.update((st) => st.copyWith(batchFolderId: v));
                  }
                },
              ),
            ),
          QmButton(
            label: _s.folderId != null ? '批量移入文件夹' : '批量加入文件夹',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: hasSelection && options.isNotEmpty
                ? () => _batchMoveToFolder(batchFolderId)
                : null,
          ),
          if (_s.folderId != null)
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
          // B11-6：批量加入 / 取消加入复习。加入复习只加未解决的错因，
          // 已治愈的不重复加入（判定在 repository.joinReviewBatch）；
          // “全部加入复习”作用域 = 当前筛选出的全部题（all 是
          // _s.filteredAll() 的结果，与“全选当前结果”同口径），不是
          // 全库、也不限当前页，不用先勾选。
          QmButton(
            label: '加入复习',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: hasSelection ? _batchJoinReviewSelected : null,
          ),
          QmButton(
            label: '全部加入复习',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: all.isNotEmpty ? () => _batchJoinReviewAll(all) : null,
          ),
          QmButton(
            label: '取消加入复习',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: hasSelection ? _batchCancelReviewSelected : null,
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
                ? () =>
                      _n.update((st) => st.copyWith(selected: const <String>{}))
                : null,
          ),
          QmButton(
            label: '退出批量',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: () => _n.update(
              (st) => st.copyWith(batchMode: false, selected: const <String>{}),
            ),
          ),
        ],
      ),
    );
  }

  /// 大卡片一题一行：卡片本身就是整题切片（外层无背景 / 无边框 /
  /// 无阴影 / 无内边距；切片白底 + 细边框，封顶 160px、按比例缩放
  /// 绝不裁切）；左上角蓝色序号圆盘；卡片上不显示题名 / 学科 /
  /// 错误类型 / 标签 / 下次复习时间 / 收藏星。
  ///
  /// B8-9：不再用固定高度内部滚动容器（>2 张卡也一样）：整页只有
  /// 一个 SingleChildScrollView，卡片全部建出来、随页滚动。
  /// A 留白卡片：每张卡独立一张白卡，14px 间距。
  Widget _buildLargeCards(List<Question> items, List<String> orderIds) {
    final scale = qmScaleOf(context);
    final cards = <Widget>[
      for (var i = 0; i < items.length; i++)
        // 序号 = 本页内的位置（1, 2, 3…），随排序 / 筛选 / 分页重编号。
        _buildLargeCard(items[i], i + 1, orderIds),
    ];
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Column(
      children: [
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) SizedBox(height: 14 * scale),
          Container(
            padding: EdgeInsets.all(12 * scale),
            decoration: BoxDecoration(
              color: palette.surface,
              border: Border.all(color: palette.line),
              borderRadius: BorderRadius.circular(DesignTokens.radius * scale),
              boxShadow: palette.shadow,
            ),
            child: cards[i],
          ),
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
          subject: _s.subjectOf(q.subjectId),
          maxHeight: 160 * scale,
          fixedHeight: true,
          onTap: () async {
            await widget.onOpenDetail(q, orderIds);
            await _n.load();
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
        if (_s.batchMode)
          Positioned(
            top: 9 * scale,
            left: DesignTokens.cardCheckLeft * scale,
            child: Container(
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(5 * scale),
              ),
              child: Checkbox(
                value: _s.selected.contains(q.id),
                onChanged: (v) => _n.toggleSelected(q.id, v == true),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCompactRows(List<Question> items, List<String> orderIds) {
    final scale = qmScaleOf(context);
    const lineKind = QmRowLineKind.line;
    return Column(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) QmRowLine(kind: lineKind),
          _buildCompactRow(items[i], orderIds),
        ],
        SizedBox(height: 4 * scale),
      ],
    );
  }

  Widget _buildCompactRow(Question q, List<String> orderIds) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final nextRecheck = _s.nextRecheckOf(q);
    return InkWell(
      onTap: () async {
        await widget.onOpenDetail(q, orderIds);
        await _n.load();
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
            if (_s.batchMode)
              Padding(
                padding: EdgeInsets.only(right: 8 * scale),
                child: Checkbox(
                  value: _s.selected.contains(q.id),
                  onChanged: (v) => _n.toggleSelected(q.id, v == true),
                ),
              ),
            GestureDetector(
              onTap: () => showQuestionZoomDialog(context, q),
              child: CompactSliceThumb(
                question: q,
                subject: _s.subjectOf(q.subjectId),
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
                      for (final (cause, status) in _s.causeStatusesOf(q))
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
  ///（纸面取浅色档），其余取纸面次级色。学科取库里的 `_s.subjects`
  ///（B2 补充；以前 `Subject.byId` 未知 id 回退到数学名 +
  /// `subjectInk` 不传存色落到数学色）。
  Widget _prowMetaLine(Question q) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final subject = _s.subjects.firstWhere(
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
    const lineKind = QmRowLineKind.line;
    return Column(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) QmRowLine(kind: lineKind),
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
        await _n.load();
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
                subject: _s.subjectOf(q.subjectId),
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
              value: _s.pageSize,
              items: [10, 20, 30, 40, 50]
                  .map((n) => DropdownMenuItem(value: n, child: Text('$n')))
                  .toList(),
              onChanged: (v) {
                if (v != null) _n.setPageSize(v);
              },
            ),
          ),
          SizedBox(width: 4 * scale),
          const Text('道', style: TextStyle(fontSize: 13.5)),
          const Spacer(),
          QmButton(
            label: '上一页',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: page > 0
                ? () => _n.update((st) => st.copyWith(page: page - 1))
                : null,
          ),
          SizedBox(width: 6 * scale),
          if (totalPages > 1)
            for (var i = 0; i < totalPages; i++) ...[
              if (i > 0) SizedBox(width: 6 * scale),
              _pageNumButton(
                i + 1,
                selected: i == page,
                onTap: () {
                  _n.update((st) => st.copyWith(page: i));
                },
              ),
            ],
          if (totalPages > 1) SizedBox(width: 6 * scale),
          QmButton(
            label: '下一页',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: page < totalPages - 1
                ? () => _n.update((st) => st.copyWith(page: page + 1))
                : null,
          ),
        ],
      ),
    );
  }

  // ----- 已归档（书架顶部入口，跨学科） -----

  Widget _buildArchived() {
    final archived = _s.questions.where((q) => q.isArchived).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final orderIds = archived.map((q) => q.id).toList();
    // 跨学科已归档视图也分页（SR-P2-46，与书内列表同一分页器，
    // 默认 10 条）：归档是只增不减的冷数据，全量渲染会越拖越长。
    // 搜索暂缓（先补分页）。
    final totalPages = (archived.length / _s.pageSize).ceil().clamp(1, 9999);
    final page = _s.page.clamp(0, totalPages - 1);
    final items = archived.skip(page * _s.pageSize).take(_s.pageSize).toList();
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
            // B8-9：与列表页同款页尾留白（分页下拉菜单贴底边会触发
            // 框架 menuLimits 断言，见 _buildList）。
            SizedBox(height: 24 * scale),
          ],
        ],
      ),
    );
  }
}
