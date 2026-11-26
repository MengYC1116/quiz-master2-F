part of 'wrongbook_page.dart';

// B8-9：题目列表样式（Meng 2026-11-15 定稿 A 留白卡片）：
// 大卡片各成一张白卡，紧凑行 / 归档行共用一张白卡；
// B 纸面通栏、C 极简线条已废弃，截图留档在
// docs/ui-replication/shots/b8-list/after-B-*.png、after-C-*.png。

// 书内列表视图：列表页、工具条、筛选面板、批量条、大卡片 / 紧凑行 / 归档行、分页与已归档视图。

/// L1 行标题（D-244，Meng 2026-11-22；2026-11-22 11:32 修订：取消
/// 15 字限制，不设字数截断）：优先显示题干 OCR 文字（displayStem：
/// 二十三批 D-250 统一口径，优先 ocrStem、回退 sliceText），
/// 无题干时回退到标题字段。题干先去 LaTeX 公式标记与换行/多余空白，
/// 完整显示、行内自动换行。
/// 详情页标题栏与导出汇总里的标题不动（仍用 q.title）。
/// 顶层公开函数：纯字符串逻辑，供 test/b21_row_title_test.dart
/// 直接单测（回退 / LaTeX / 空白折叠 / 完整显示）。
String rowDisplayTitle(Question q) {
  final stem = stripLatexForRow(q.displayStem).replaceAll(
    RegExp(r'\s+'),
    ' ',
  ).trim();
  if (stem.isEmpty) return q.title;
  return stem;
}

/// 行标题去 LaTeX：`$…$` / `$$…$$` / `\(…\)` / `\[…\]` 整段
/// 去掉（只留纯文本），不成对的 `$` 也去掉。公式本身仍在详情页
/// 纸面与题干区正常渲染，这里只是行内不露源码。
/// 简化口径：假定成对 `$` 都是公式定界符（题干里 `$` 作货币
/// 符的情形未见，遇上会误删中间文字）。
String stripLatexForRow(String text) {
  return text
      .replaceAll(RegExp(r'\$\$.*?\$\$', dotAll: true), ' ')
      .replaceAll(RegExp(r'\$.*?\$', dotAll: true), ' ')
      .replaceAll(RegExp(r'\\\(.*?\\\)', dotAll: true), ' ')
      .replaceAll(RegExp(r'\\\[.*?\\\]', dotAll: true), ' ')
      .replaceAll('\$', '');
}

extension _WrongbookListBuild on _WrongbookViewState {
  /// 十九批 A1：L1 列表页（命令面板式，一比一复刻板子 §1）。
  ///
  /// 自上而下：页头（标题＋← 目录 / 合上 ✕，二十三批 D-250 从
  /// 十七批版恢复）→ 副标题 → 大搜索框 → 范围说明行 →
  /// 「我的查找」行 → 「最近搜过」行 → 结果头（标题＋计数＋
  /// 排序＋筛选＋批量）→ 导出模式入口 / 提示条 → 筛选面板
  /// （点「筛选 ▾」展开）→ 已掌握提示 / 归档条 / 批量条 →
  /// 列表行 → 分页行 → 底部汇总条（仅导出模式）。
  /// 视图切换已去掉：只用板子一种行设计（_buildBoardRow），
  /// `viewMode` 字段与 load() 守门保留在 Notifier 里不用。
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
    // B8-9：去掉蓝色大框（_openBookFrame）：搜索框 / 结果头 / 列表 /
    // 分页直接落在页面底色上。目录页的书框不动（那是目录页的样式，
    // 不在本次范围）。
    // 十六批 B（D-190）→ 十九批 A2：汇总条只在导出模式显示
    //（板子 §1.6：平时 display:none），固定在底部不随列表滚动；
    // 已归档视图没有导出勾选，不画汇总条。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildListHeader(title, scale),
                _pageSubtitle('这一科的题目列表，点一道题进题目详情；筛选里没有文件夹，文件夹在目录页选。'),
                _buildBigSearch(),
                _buildSavedSearchRow(),
                _buildRecentSearchRow(),
                _buildResultHead(all.length),
                _buildExportToggle(),
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
          ),
        ),
        if (_exportMode && !_s.inBookArchived) _buildExportSummaryBar(items),
      ],
    );
  }

  /// 列表页头（标题 + 目录 / 合上按钮）：二十三批 D-250 从十七批版
  /// （c086ca8）原样恢复。「← 目录」：有学科进目录、无学科回书架；
  /// 「合上 ✕」：回书架。
  Widget _buildListHeader(String title, double scale) {
    return Row(
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
    );
  }

  /// 底部汇总条（十九批 A2，板子 §1.6）：仅导出模式显示，深色底
  /// `#17233B` 白字、圆角 10、上边距 12。左起：已选文案（未选时
  /// `已选 0 道`，选中后 `已选 N 道：题名1、题名2…`）→ `全选本页` →
  /// `清空` → 弹性空隙 → `退出导出` → `下一步：选版本与文件名 →`
  ///（主按钮，蓝底）。点「下一步」走现版 ExportConfirmDialog
  ///（快照语义 R13 不变）；点「退出导出」只退模式，已选保留
  ///（D-208）。不画旧的展开清单与盘点跳过信息（板子没有）。
  Widget _buildExportSummaryBar(List<Question> pageItems) {
    final scale = qmScaleOf(context);
    final selectedQs = _exportSelectedQuestions(_s);
    final count = selectedQs.length;
    final sumText = count == 0
        ? '已选 0 道'
        : '已选 $count 道：${selectedQs.map((q) => q.title).join('、')}';
    return Container(
      key: const Key('export-summary-bar'),
      margin: EdgeInsets.only(top: 12 * scale),
      padding: EdgeInsets.symmetric(
        horizontal: 14 * scale,
        vertical: 10 * scale,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF17233B),
        borderRadius: BorderRadius.circular(10 * scale),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              sumText,
              key: const Key('export-summary-numbers'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13.5, color: Colors.white),
            ),
          ),
          SizedBox(width: 10 * scale),
          _summaryButton(
            '全选本页',
            key: const Key('export-select-page'),
            onPressed: () => _selectAllExportOnPage(pageItems),
          ),
          SizedBox(width: 8 * scale),
          _summaryButton(
            '清空',
            key: const Key('export-clear'),
            onPressed: count == 0
                ? null
                : () {
                    _n.clearExportSelected();
                  },
          ),
          const Spacer(),
          _summaryButton(
            '退出导出',
            key: const Key('export-exit'),
            onPressed: _exitExportMode,
          ),
          SizedBox(width: 8 * scale),
          _summaryButton(
            '下一步：选版本与文件名 →',
            key: const Key('export-next'),
            primary: true,
            onPressed: _openExportConfirm,
          ),
        ],
      ),
    );
  }

  /// 汇总条按钮（板子 `.sbtn`）：白字透明底、白边、圆角 8、最小高
  /// 32；主按钮（`.sbtn.go`）蓝底 `#2E7CF6` 蓝边、字重 600。
  Widget _summaryButton(
    String label, {
    Key? key,
    required VoidCallback? onPressed,
    bool primary = false,
  }) {
    final scale = qmScaleOf(context);
    return TextButton(
      key: key,
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white.withValues(alpha: 0.45),
        backgroundColor: primary ? const Color(0xFF2E7CF6) : Colors.transparent,
        side: BorderSide(
          color: primary ? const Color(0xFF2E7CF6) : Colors.white,
        ),
        padding: EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 4 * scale),
        minimumSize: Size(0, 32 * scale),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8 * scale),
        ),
        textStyle: TextStyle(
          fontSize: 13.5,
          fontWeight: primary ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      child: Text(label),
    );
  }

  /// 汇总条「全选本页」：把本页未选的题逐个点选（50 道硬上限仍由
  /// toggleExportSelected 守：到上限时弹一次提示就停，不再往下点）。
  void _selectAllExportOnPage(List<Question> pageItems) {
    for (final q in pageItems) {
      if (_sr.exportSelected.contains(q.id)) continue;
      if (_toggleExportSelected(q.id) != null) break;
    }
  }

  /// 列表本体（含空状态）：十九批 A1——只用板子一种行设计
  ///（_buildBoardRow），大卡片 / 紧凑行已随视图切换去掉；
  /// 归档行仍共用一张白卡（_listSurface）。
  Widget _buildListBody(List<Question> items, List<String> orderIds) {
    if (items.isEmpty) return _buildListEmpty();
    if (_s.inBookArchived) {
      return _listSurface(child: _buildArchivedRows(items, orderIds));
    }
    final scale = qmScaleOf(context);
    return Column(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) SizedBox(height: 8 * scale),
          // 二十二批 D-247：行轻微错开入场（行号 × 30ms，上限 8 行）。
          EntranceFadeSlide(
            delay: Duration(milliseconds: (i > 8 ? 8 : i) * 30),
            child: _buildBoardRow(items[i], orderIds),
          ),
        ],
      ],
    );
  }

  /// 板子行（L1 §1.4）：白底、1px 边、圆角 10、内边距 10/12、行距 8。
  /// 第一行（左→右）：学科圆点（9px）→ 标题（14.5px/600，可换行…
  /// 标题过长时省略，板子未定行数，这里单行省略）→ 状态 pill →
  /// 逾期红字（有则）→ 右侧收集时间（12.5px）→ 导出 ✓（仅选中行，
  /// 22px 蓝圆白字）；第二行：meta 归属行（独占一行，12.5px，
  /// `文件夹 · 知识点 · 错因 · 标签 · 试卷`，缺失项省略）。
  /// 命中字段按搜索关键词高亮（#FFF1B8）。批量模式时行首多个
  /// Checkbox（勾选与点行进详情分开，沿用旧行为）；导出模式点行
  /// 即切换导出选中、不进详情（B12）；平时点行进详情，点按末尾
  /// `await _n.load()`（R3：详情返回刷新唯一链路）。
  Widget _buildBoardRow(Question q, List<String> orderIds) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final exportChecked = _s.exportSelected.contains(q.id);
    final keyword = _s.search.trim().isEmpty ? null : _s.search.trim();
    final subject = _s.subjectOf(q.subjectId);
    final collected =
        '${q.createdAt.month.toString().padLeft(2, '0')}-${q.createdAt.day.toString().padLeft(2, '0')} 收集';
    return InkWell(
      onTap: () async {
        // 十七批 P2（D-208）：导出模式里点行即切换导出选中，
        // 不进详情；模式外照常进详情（带 searchContext，A6）。
        if (_exportMode) {
          _toggleExportSelected(q.id);
          return;
        }
        await widget.onOpenDetail(
          q,
          orderIds,
          searchContext: _searchContext(),
        );
        await _n.load();
      },
      borderRadius: BorderRadius.circular(10 * scale),
      child: Container(
        key: ValueKey('export-row-${q.id}'),
        padding: EdgeInsets.symmetric(
          horizontal: 12 * scale,
          vertical: 10 * scale,
        ),
        decoration: BoxDecoration(
          color: exportChecked ? palette.accentSoft : palette.surface,
          border: Border.all(color: palette.line),
          borderRadius: BorderRadius.circular(10 * scale),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
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
                Padding(
                  padding: EdgeInsets.only(top: 5 * scale, right: 6 * scale),
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: subject.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Expanded(
                  child: RichText(
                    // D-244 修订（2026-11-22 11:32）：不设字数截断，
                    // 题干完整显示、自动换行。
                    text: TextSpan(
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: palette.ink,
                      ),
                      children: _highlightSpans(
                        rowDisplayTitle(q),
                        keyword,
                      ),
                    ),
                  ),
                ),
                // 收藏标志（2026-11-26，用户要求列表可区分收藏）：
                // 已收藏的题在题干后、状态 pill 前画 ★，与详情页
                // 同星形同色（paperStarOn）；只展示，不拦截点行进详情。
                if (q.isFavorite) ...[
                  SizedBox(width: 6 * scale),
                  Text(
                    '★',
                    key: ValueKey('favorite-star-${q.id}'),
                    style: TextStyle(
                      fontSize: DesignTokens.detailStarFontSize,
                      color: palette.paperStarOn,
                      height: 1,
                    ),
                  ),
                ],
                SizedBox(width: 8 * scale),
                _statusPill(q),
                // P3 入口 1：已在 FSRS 复习池的题行内标“已在复习”
                //（不计入新增数，点加入时自动跳过）。
                if (_s.isInReviewPool(q)) ...[
                  SizedBox(width: 6 * scale),
                  Text(
                    '已在复习',
                    key: ValueKey('in-review-${q.id}'),
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF0B7A55),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                if (_overdueDays(q) > 0) ...[
                  SizedBox(width: 6 * scale),
                  Text(
                    '逾期 ${_overdueDays(q)} 天',
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: Color(0xFFEF4444),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                SizedBox(width: 8 * scale),
                Text(
                  collected,
                  style: TextStyle(fontSize: 12.5, color: palette.muted),
                ),
                // 十七批 P2（D-208）：选中行的 ✓ 在行右端
                //（蓝底见行容器；22px 蓝圆白字，板子 §1.6）。
                if (exportChecked) ...[
                  SizedBox(width: 6 * scale),
                  Container(
                    key: ValueKey('export-mark-${q.id}'),
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: Color(0xFF2E7CF6),
                      shape: BoxShape.circle,
                    ),
                    child: const Text(
                      '✓',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        height: 1,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            SizedBox(height: 4 * scale),
            _metaLine(q, keyword),
          ],
        ),
      ),
    );
  }

  /// 行状态 pill（板子 §1.4，四态配色；解决中带自查进度
  /// `解决中 · ✓n/m`，m = 设置 cureChecks，n = 首个未治愈错因的
  /// 已解决自查次数；待复查 pill 字重 600）。
  Widget _statusPill(Question q) {
    final status = _s.causeStatusOf(q);
    final (bg, fg, label, bold) = switch (status) {
      'inProgress' => (
        const Color(0xFFFFF4D6),
        const Color(0xFF8A6D00),
        '解决中 · ✓${_inProgressCount(q)}/${_s.cureChecks}',
        false,
      ),
      'solved' => (
        const Color(0xFFE2F5EC),
        const Color(0xFF0B7A55),
        '已解决',
        false,
      ),
      'recheck' => (
        const Color(0xFFE1EDFF),
        const Color(0xFF2E7CF6),
        '待复查',
        true,
      ),
      _ => (
        const Color(0xFFFDECEC),
        const Color(0xFFC62828),
        '待解决',
        false,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9),
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: fg,
          fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
          height: 1,
        ),
      ),
    );
  }

  /// 首个未治愈错因的已解决自查次数（状态 pill `✓n/m` 里的 n）。
  int _inProgressCount(Question q) {
    final rs = _s.recordsByQ[q.id];
    if (rs == null) return 0;
    for (final r in rs) {
      if (r.status != CauseStatus.solved) return r.solvedCount;
    }
    return 0;
  }

  /// 逾期天数（0 = 未逾期）：到复查时间的错因里，复查日距今天最远的。
  int _overdueDays(Question q) {
    final rs = _s.recordsByQ[q.id];
    if (rs == null) return 0;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    var max = 0;
    for (final r in rs) {
      if (!r.isRecheckDue || r.recheckDate == null) continue;
      final d = DateTime(
        r.recheckDate!.year,
        r.recheckDate!.month,
        r.recheckDate!.day,
      );
      final days = today.difference(d).inDays;
      if (days > max) max = days;
    }
    return max;
  }

  /// 命中高亮（板子 `.hl`：#FFF1B8 底、圆角 3）：在 [text] 里按
  /// [keyword]（大小写不敏感）切出命中的子串；无关键词时原样返回。
  List<InlineSpan> _highlightSpans(String text, String? keyword) {
    const hlBg = Color(0xFFFFF1B8);
    if (keyword == null || keyword.isEmpty) {
      return [TextSpan(text: text)];
    }
    final lower = text.toLowerCase();
    final kw = keyword.toLowerCase();
    final spans = <InlineSpan>[];
    var start = 0;
    while (true) {
      final idx = lower.indexOf(kw, start);
      if (idx < 0) {
        if (start < text.length) {
          spans.add(TextSpan(text: text.substring(start)));
        }
        break;
      }
      if (idx > start) {
        spans.add(TextSpan(text: text.substring(start, idx)));
      }
      spans.add(
        TextSpan(
          text: text.substring(idx, idx + kw.length),
          style: const TextStyle(backgroundColor: hlBg),
        ),
      );
      start = idx + kw.length;
      if (start >= text.length) break;
    }
    return spans;
  }

  /// meta 归属行（板子 §1.4）：`文件夹 {…} · 知识点 {…} · 错因 {…} ·
  /// 标签 {…} · {试卷名}`，缺失项直接省略不留空位；命中的字段按
  /// 搜索关键词高亮。文件夹 / 知识点 / 错因 / 标签多值时用 `、` 连接。
  Widget _metaLine(Question q, String? keyword) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final baseStyle = TextStyle(fontSize: 12.5, color: palette.muted);
    final parts = <(String, String)>[];
    final folderNames = q.folderIds
        .map(
          (id) => _s.folders
              .firstWhere(
                (f) => f.id == id,
                orElse: () => Folder(id: id, name: '', subjectId: ''),
              )
              .name,
        )
        .where((n) => n.isNotEmpty)
        .toList();
    if (folderNames.isNotEmpty) {
      parts.add(('文件夹 ', folderNames.join('、')));
    }
    final kpNames = q.knowledgePointIds
        .map(
          (id) => _s.kps
              .firstWhere(
                (k) => k.id == id,
                orElse: () => const KnowledgePoint(
                  id: '',
                  subjectId: '',
                  chapter: '',
                  name: '',
                ),
              )
              .name,
        )
        .where((n) => n.isNotEmpty)
        .toList();
    if (kpNames.isNotEmpty) parts.add(('知识点 ', kpNames.join('、')));
    if (q.allCauses.isNotEmpty) {
      parts.add(('错因 ', q.allCauses.join('、')));
    }
    if (q.tags.isNotEmpty) parts.add(('标签 ', q.tags.join('、')));
    final examName = _s.exams
        .firstWhere(
          (e) => e.id == q.examId,
          orElse: () => Exam(id: '', name: ''),
        )
        .name;
    if (examName.isNotEmpty) parts.add(('', examName));
    final children = <InlineSpan>[];
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) children.add(const TextSpan(text: ' · '));
      final (prefix, value) = parts[i];
      if (prefix.isNotEmpty) children.add(TextSpan(text: prefix));
      children.addAll(_highlightSpans(value, keyword));
    }
    return RichText(
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(style: baseStyle, children: children),
    );
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

  // ---------- 十九批 A1：大搜索框 / 我的查找 / 最近搜过 / 结果头 ----------

  /// 大搜索框（板子 §1.2）：白底、2px #2E7CF6 边框、圆角 14、内边距
  /// 12/16、字号 16、阴影 `0 4px 18px rgba(46,124,246,.14)`；左起
  /// 放大镜 → 输入框（占位「搜标题、题干、选项、答案、解析、备注…」）。
  /// 二十一批（D-242）：框内深色 Ctrl+K kbd 已去掉（Meng 2026-11-22：
  /// 框里多个小框不好看）；命令面板仍可用 Ctrl+K 呼出，入口在下方
  /// 范围说明行的浅色 kbd。
  /// 就是现版搜索输入框（同一 _searchCtrl、同一 setSearch()、同一
  /// haystack；D-241 起内容搜索）。输入即实时过滤；回车
  /// 把关键词记入「最近搜过」（D-决策第 4 项）。
  Widget _buildBigSearch() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: EdgeInsets.only(top: 12 * scale),
          decoration: BoxDecoration(
            color: palette.surface,
            border: Border.all(color: palette.accent, width: 2),
            borderRadius: BorderRadius.circular(14 * scale),
            boxShadow: const [
              BoxShadow(
                offset: Offset(0, 4),
                blurRadius: 18,
                color: Color.fromRGBO(46, 124, 246, 0.14),
              ),
            ],
          ),
          padding: EdgeInsets.symmetric(
            horizontal: 16 * scale,
            vertical: 12 * scale,
          ),
          child: Row(
            children: [
              const Text('🔍', style: TextStyle(fontSize: 19)),
              SizedBox(width: 10 * scale),
              Expanded(
                child: TextField(
                  key: const Key('big-search'),
                  controller: _searchCtrl,
                  style: const TextStyle(fontSize: 16),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    hintText: '搜标题、题干、选项、答案、解析、备注…',
                    hintStyle: TextStyle(color: Color(0xFF94A3B8)),
                    contentPadding: EdgeInsets.zero,
                  ),
                  onChanged: (v) => _n.setSearch(v),
                  onSubmitted: (v) => _n.recordKeywordSearch(v),
                ),
              ),
            ],
          ),
        ),
        // 范围说明行（板子 `.scope-note`，12.5px #64748B）：
        // 板子原文还提到页面右下角的「试试命令面板」浮动按钮，
        // 该按钮是演示用呼出方式、不进应用（协调员决策），这里
        // 只保留“搜索范围 + 点 Ctrl+K 呼出面板”两层意思，
        // Ctrl/K 浅色 kbd 可点（框内深色 kbd 二十一批已去掉）。
        Padding(
          padding: EdgeInsets.only(top: 8 * scale, left: 2 * scale),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '可搜标题、题干、选项、答案、解析、备注，也搜文件夹、标签、错因、知识点、试卷。点 ',
                style: TextStyle(fontSize: 12.5, color: palette.muted),
              ),
              GestureDetector(
                onTap: _openCommandPalette,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _kbd('Ctrl', light: true),
                    SizedBox(width: 4 * scale),
                    _kbd('K', light: true),
                  ],
                ),
              ),
              Text(
                ' 呼出命令面板。',
                style: TextStyle(fontSize: 12.5, color: palette.muted),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// kbd（板子 §1.2）：深色版 #17233B 底白字；浅色版（`kbd.lt`）
  /// #E8EDF3 底 #475569 字；圆角 5、内边距 1/6、字号 11.5。
  Widget _kbd(String text, {bool light = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: light ? const Color(0xFFE8EDF3) : const Color(0xFF17233B),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          color: light ? const Color(0xFF475569) : Colors.white,
        ),
      ),
    );
  }

  /// L1 chip（板子 `.fchip`）：白底、1px #E3E8F0 边、圆角 999、
  /// 内边距 4/12、字号 13、最小高 32。saved 态（`.fchip.saved`）：
  /// 虚线蓝边 + 蓝字；选中态（`.fchip.on`）：蓝底白字、字重 600。
  Widget _l1Chip({
    required String label,
    required VoidCallback onTap,
    bool saved = false,
    bool selected = false,
    VoidCallback? onDelete,
  }) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: selected ? Colors.white : (saved ? palette.accent : palette.ink),
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
        if (onDelete != null) ...[
          SizedBox(width: 6 * scale),
          GestureDetector(
            onTap: onDelete,
            child: Text(
              '✕',
              style: TextStyle(
                fontSize: 12,
                color: selected ? Colors.white : palette.muted,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ],
    );
    final inner = Container(
      constraints: BoxConstraints(minHeight: 32 * scale),
      padding: EdgeInsets.symmetric(horizontal: 12 * scale, vertical: 4 * scale),
      decoration: BoxDecoration(
        color: selected ? palette.accent : palette.surface,
        borderRadius: BorderRadius.circular(999 * scale),
        border: saved || selected
            ? null
            : Border.all(color: palette.line),
      ),
      child: content,
    );
    final dashed = (saved && !selected)
        ? CustomPaint(
            painter: _DashedBorderPainter(
              color: palette.accent,
              borderRadius: BorderRadius.circular(999 * scale),
              strokeWidth: 1,
            ),
            child: inner,
          )
        : inner;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999 * scale),
      child: dashed,
    );
  }

  /// 「我的查找」行（板子 §1.3.1）：`我的查找：` + 已存 chip
  ///（`★ {名字}`，虚线蓝边；当前条件与该条相等时选中态）+
  /// `＋ 存当前条件`。chip 点按应用条件、结果头与计数联动、
  /// toast `已应用查找：{名字}`；chip 上小 × 删除（无确认，
  /// 删了可重存）。为空时只显示存条件按钮。
  Widget _buildSavedSearchRow() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final currentKey = conditionsKey(_s.currentConditions());
    return Padding(
      padding: EdgeInsets.only(top: 12 * scale, bottom: 4 * scale),
      child: Wrap(
        spacing: 8 * scale,
        runSpacing: 8 * scale,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '我的查找：',
            style: TextStyle(
              fontSize: 13,
              color: palette.muted,
              fontWeight: FontWeight.w600,
            ),
          ),
          for (final saved in _s.savedSearches)
            _l1Chip(
              label: '★ ${saved.name}',
              saved: true,
              selected: conditionsKey(saved.conditions) == currentKey,
              onTap: () => _applySearchConditions(
                saved.conditions,
                label: saved.name,
                toast: '已应用查找：${saved.name}',
              ),
              onDelete: () => _deleteSavedSearch(saved),
            ),
          _l1Chip(label: '＋ 存当前条件', onTap: _openSaveSearchDialog),
        ],
      ),
    );
  }

  /// 「最近搜过」行（板子 §1.3.2）：`最近搜过：` + chip（点按联动
  /// 搜索框 / 结果头 / 计数 + toast，与「我的查找」同款）。
  /// 为空时整行不画。
  Widget _buildRecentSearchRow() {
    if (_s.recentSearches.isEmpty) return const SizedBox.shrink();
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Padding(
      padding: EdgeInsets.only(top: 4 * scale, bottom: 4 * scale),
      child: Wrap(
        spacing: 8 * scale,
        runSpacing: 8 * scale,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '最近搜过：',
            style: TextStyle(
              fontSize: 13,
              color: palette.muted,
              fontWeight: FontWeight.w600,
            ),
          ),
          for (final recent in _s.recentSearches)
            _l1Chip(
              label: recent.name,
              onTap: () => _applySearchConditions(
                recent.conditions,
                label: recent.name,
                toast: '已应用查找：${recent.name}',
              ),
            ),
        ],
      ),
    );
  }

  /// 应用一份查找条件（saved / 最近 / 命令面板共用）：Notifier
  /// 改状态（并记入最近搜过），页面同步搜索框文字、弹 toast。
  /// 无搜索关键词的条件进列表时搜索框清空（条件里的 search 为空
  /// 时 _searchCtrl 不同步会残留旧词，与结果对不上）。
  void _applySearchConditions(
    Map<String, dynamic> conditions, {
    String? label,
    String? toast,
  }) {
    _n.applySearchConditions(conditions, label: label);
    final search = normalizeConditions(conditions)['search'] as String?;
    _searchCtrl.text = search ?? '';
    if (toast != null) _snack(toast);
  }

  /// 删一条已存查找（chip 上的小 ×，无确认）。
  Future<void> _deleteSavedSearch(SavedSearch saved) async {
    await _n.deleteSavedSearch(saved.id);
    if (mounted) _snack('已删除查找：${saved.name}');
  }

  /// 「＋ 存当前条件」命名对话框（板子未注明保存交互，协调员决策
  /// 第 5 项）：名字默认取当前条件的描述（空条件为「全部题目」），
  /// 可改；保存后 toast `已保存查找：{名字}`。
  Future<void> _openSaveSearchDialog() async {
    _saveSearchNameCtrl.text =
        _describeConditions(_s.currentConditions(), includeScope: true);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('存当前条件'),
        content: TextField(
          key: const Key('save-search-name'),
          controller: _saveSearchNameCtrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '给这次查找起个名字'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final msg = await _n.saveCurrentSearch(_saveSearchNameCtrl.text);
    if (!mounted) return;
    if (msg != null) {
      _snack(msg);
      return;
    }
    _snack('已保存查找：${_saveSearchNameCtrl.text.trim()}');
  }

  /// 结果头（板子 §1.3.3）：标题（15px/700）+ 计数（13px）+
  /// 右侧排序下拉 +「筛选 ▾」+ 批量入口（批量模式保留在结果头
  /// 工具栏区，协调员决策第 8 项）。
  /// 标题：搜关键词时为「「{关键词}」的结果」；有筛选时为
  /// 「「{筛选描述}」的结果」；否则「全部题目」（学科 / 文件夹
  /// 归属范围不进标题，页头已显示）。
  Widget _buildResultHead(int total) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final filterCount = _s.activeFilterCount();
    final sortLabel = switch (_s.sort) {
      'old' => '收集时间 旧 → 新',
      'subj-asc' || 'subject' => '学科首字母 A → Z',
      'subj-desc' => '学科首字母 Z → A',
      'status-asc' => '错因状态 待解决 → 已解决',
      'status-desc' => '错因状态 已解决 → 待解决',
      _ => '收集时间 新 → 旧',
    };
    return Padding(
      padding: EdgeInsets.only(top: 14 * scale, bottom: 8 * scale),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Flexible(
            child: Wrap(
              spacing: 10 * scale,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  _resultTitle(),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '共 $total 道 · 按$sortLabel',
                  style: TextStyle(fontSize: 13, color: palette.muted),
                ),
              ],
            ),
          ),
          const Spacer(),
          SizedBox(
            width: 200 * scale,
            child: _styledDropdown<String>(
              value: _s.sort,
              items: const [
                DropdownMenuItem(value: 'new', child: Text('排序：时间新 → 旧')),
                DropdownMenuItem(value: 'old', child: Text('排序：时间旧 → 新')),
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
          SizedBox(width: 8 * scale),
          QmChip(
            label: filterCount > 0
                ? '筛选（已选 $filterCount）${_s.filterOpen ? ' ▴' : ' ▾'}'
                : '筛选${_s.filterOpen ? ' ▴' : ' ▾'}',
            selected: _s.filterOpen,
            onTap: () =>
                _n.update((st) => st.copyWith(filterOpen: !st.filterOpen)),
          ),
          if (!_s.inBookArchived) ...[
            SizedBox(width: 8 * scale),
            QmChip(
              label: '批量操作',
              selected: _s.batchMode,
              // 十八批 P2（D-217）：与导出模式彻底互斥，进批量时退
              // 导出模式并清空导出已选（D-209 的「取消保留已选」只
              // 适用于点「取消」退出，不适用于进批量）。
              onTap: _toggleBatchMode,
            ),
            // 二十一批 D-243：导出入口「导出打印」与排序/筛选/
            // 批量操作并排（原先是结果头下方的独立虚线行）。
            // 模式里不画（取消/导出（n）在下方控制区）。
            if (!_exportMode) ...[
              SizedBox(width: 8 * scale),
              QmChip(
                key: const Key('export-selected-toolbar'),
                label: '导出打印',
                onTap: _enterExportMode,
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// 结果头标题：见 _buildResultHead 注释。
  String _resultTitle() {
    if (_s.search.trim().isNotEmpty) return '「${_s.search.trim()}」的结果';
    // 范围（学科 / 文件夹）只进页头，不进结果标题：去掉范围键后
    // 还有条件才是「筛选后的结果」；否则标题就是「全部题目」。
    // 不能用 desc 是否为空判断——_describeConditions 空条件回退
    // 成「全部题目」当名字，旧代码会拼出「「全部题目」的结果」。
    final conditions = normalizeConditions(_s.currentConditions())
      ..remove('subjectId')
      ..remove('folderId');
    if (conditions.isEmpty) return '全部题目';
    final desc = _describeConditions(
      _s.currentConditions(),
      includeScope: false,
      includeSearch: false,
    );
    return '「$desc」的结果';
  }

  /// 条件的人话描述（` · ` 连接；空条件为「全部题目」）：
  /// 学科名 / 文件夹名 / 错因名 / 状态 / 试卷名 / 错误类型 /
  /// 题型 / 时间范围 / 仅收藏 / 仅逾期 / 标签 / 知识点名 /
  /// 搜索关键词。保存命名默认值与结果头标题共用（includeScope /
  /// includeSearch 控制是否含范围与关键词）。
  String _describeConditions(
    Map<String, dynamic> conditions, {
    bool includeScope = true,
    bool includeSearch = true,
  }) {
    final c = normalizeConditions(conditions);
    final parts = <String>[];
    if (includeScope) {
      final subjectId = c['subjectId'] as String?;
      if (subjectId != null) {
        final name = _s.subjects
            .where((s) => s.id == subjectId)
            .map((s) => s.name)
            .firstOrNull;
        if (name != null) parts.add(name);
      }
      final folderId = c['folderId'] as String?;
      if (folderId != null) {
        final folder = _s.folderById(folderId);
        if (folder != null) parts.add(folder.name);
      }
    }
    final cause = c['cause'] as String?;
    if (cause != null) parts.add(cause);
    final causeStatus = c['causeStatus'] as String?;
    if (causeStatus != null) {
      parts.add(
        switch (causeStatus) {
          'pending' => '待解决',
          'inProgress' => '解决中',
          'solved' => '已解决',
          'recheck' => '待复查',
          _ => causeStatus,
        },
      );
    }
    final examId = c['examId'] as String?;
    if (examId != null) {
      final name = _s.exams
          .where((e) => e.id == examId)
          .map((e) => e.name)
          .firstOrNull;
      if (name != null) parts.add(name);
    }
    final errorType = c['errorType'] as String?;
    if (errorType != null) parts.add(errorType);
    final questionType = c['questionType'] as String?;
    if (questionType != null) {
      parts.add(questionTypeLabels[questionType] ?? questionType);
    }
    final timeRange = c['timeRange'] as String?;
    if (timeRange != null) {
      parts.add(timeRange == 'week' ? '最近一周' : '最近 30 天');
    }
    if (c['favorite'] == true) parts.add('仅收藏');
    if (c['overdue'] == true) parts.add('仅逾期');
    final tags = c['tags'];
    if (tags is List && tags.isNotEmpty) {
      parts.add('标签：${tags.whereType<String>().join('、')}');
    }
    final kpIds = c['kpIds'];
    if (kpIds is List && kpIds.isNotEmpty) {
      final names = kpIds
          .whereType<String>()
          .map(
            (id) => _s.kps
                .where((k) => k.id == id)
                .map((k) => k.name)
                .firstOrNull,
          )
          .whereType<String>()
          .toList();
      if (names.isNotEmpty) parts.add(names.join('、'));
    }
    if (includeSearch) {
      final search = c['search'] as String?;
      if (search != null && search.trim().isNotEmpty) {
        parts.add(search.trim());
      }
    }
    return parts.isEmpty ? '全部题目' : parts.join(' · ');
  }

  /// searchContext（A6）：行点按时拼的查询描述——学科名 / 错因名 /
  /// 状态 / 搜索关键词，非空部分用 ` · ` 连接；全空为「全部题目」。
  /// 错因名取 filterCauseName（报告深链）或 filterErrorType
  ///（错误类型筛选），状态取 filterCauseStatus 的中文。
  String _searchContext() {
    final parts = <String>[];
    if (_s.subjectId != null) {
      parts.add(_s.subjectOf(_s.subjectId!).name);
    }
    final cause = _s.filterCauseName ?? _s.filterErrorType;
    if (cause != null) parts.add(cause);
    if (_s.filterCauseStatus != 'all') {
      parts.add(
        switch (_s.filterCauseStatus) {
          'pending' => '待解决',
          'inProgress' => '解决中',
          'solved' => '已解决',
          'recheck' => '待复查',
          _ => _s.filterCauseStatus,
        },
      );
    }
    if (_s.search.trim().isNotEmpty) parts.add(_s.search.trim());
    return parts.isEmpty ? '全部题目' : parts.join(' · ');
  }

  /// 导出模式控制区（板子 §1.6 的入口已搬走）：平时不画东西——
  /// 入口「导出打印」在结果头那一行，与排序/筛选/批量操作并排
  /// （二十一批 D-243，Meng 2026-11-22）；模式里：`取消` +
  /// `导出（n）`（n=0 置灰）+ 黄色提示条（`导出模式中：点一行即选中
  /// （不会进详情），选中行蓝底、右端出现 ✓；再点一次取消。`）。
  /// 入口按钮 key 沿用 `export-selected-toolbar`（旧测试按 key 找
  /// 入口，现落在结果头的 chip 上）；提示条 key 沿用 `export-mode-hint`。
  Widget _buildExportToggle() {
    final scale = qmScaleOf(context);
    if (_s.inBookArchived) return const SizedBox.shrink();
    if (_exportMode) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8 * scale,
            runSpacing: 8 * scale,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              QmButton(
                key: const Key('export-mode-cancel'),
                label: '取消',
                variant: QmButtonVariant.plain,
                size: QmButtonSize.small,
                onPressed: _exitExportMode,
              ),
              QmButton(
                key: const Key('export-selected-toolbar'),
                label: _s.exportSelected.isEmpty
                    ? '导出'
                    : '导出（${_s.exportSelected.length}）',
                variant: QmButtonVariant.secondary,
                size: QmButtonSize.small,
                onPressed: _s.exportSelected.isEmpty
                    ? null
                    : _openExportConfirm,
              ),
            ],
          ),
          Container(
            key: const Key('export-mode-hint'),
            margin: EdgeInsets.only(top: 10 * scale, bottom: 10 * scale),
            padding: EdgeInsets.symmetric(
              horizontal: 12 * scale,
              vertical: 6 * scale,
            ),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF4D6),
              borderRadius: BorderRadius.circular(8 * scale),
            ),
            child: const Text(
              '导出模式中：点一行即选中（不会进详情），选中行蓝底、右端出现 ✓；再点一次取消。',
              style: TextStyle(fontSize: 13, color: Color(0xFF8A6D00)),
            ),
          ),
        ],
      );
    }
    // 二十一批 D-243：入口已搬进结果头（「导出打印」chip），
    // 平时这里不画东西；模式里的取消/导出（n）+ 提示条见上。
    return const SizedBox.shrink();
  }

  /// 命令面板（十九批 A4）：本页内呼出（大搜索框 Ctrl+K kbd、
  /// scope-note kbd）；选中后直接应用（已在错题本，不用走
  /// app 层的 pending 机制），toast 用板子文案。
  void _openCommandPalette() {
    unawaited(
      showDialog<void>(
        context: context,
        barrierColor: const Color.fromRGBO(15, 23, 42, 0.45),
        barrierDismissible: true,
        builder: (dctx) => CommandPalette(
          repo: ref.read(repositoryProvider),
          onApply: (conditions, label) => _applySearchConditions(
            conditions,
            label: label,
            toast: '已用命令面板打开查找：$label',
          ),
        ),
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
        crossAxisAlignment: CrossAxisAlignment.start,
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
                  '错因',
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
              // 十九批 A1：旧工具栏的「重置」随工具栏一起拆了，功能
              // 挪到筛选面板「只看」行末尾（清搜索与筛选、排序回
              // 时间新→旧，SR-P2-58）。
              QmChip(label: '重置', onTap: _resetFilters),
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

  /// 方案 A 批量栏：单行工具条（替代旧三行平铺面板）。
  ///
  /// 左：已选文案 +「选择 ▾」（全选当前结果 / 勾选当前页 /
  /// 全选全部筛选结果 / 清除选择）；中：「整理 ▾」（移入文件夹 ▸ /
  /// 移出当前文件夹 / 加标签 / 收藏 / 归档）、「复习 ▾」（加入复习 /
  /// 全部加入复习 / 立即专项练习 / 取消加入复习）；右：批量删除
  /// （两段确认）+ 退出批量。导出打印在标题行，不动。
  ///
  /// 「全选当前结果」与「勾选当前页」不是同一动作（前者把全部筛
  /// 选结果同时填进通用选择与加题选择、可 toggle；后者只把当页
  /// 题加进加题选择），两个都保留。「全部加入复习」按 2026-11-25
  /// Meng 定“两按钮都加”放回：与“加入复习”不是同一动作（前者
  /// 作用域是全部筛选结果、不用先勾选，后者只作用于已勾选）。
  ///
  /// 启用态按各菜单动作实际读的选择集：整理 / 删除读通用选择，
  /// 复习读加题选择（reviewEffectiveIds），选择 / 退出始终可用。
  /// 0 选时整理 / 删除禁用；复习菜单保持可点，里面只有「全部加
  /// 入复习」可用（它只要筛选结果非空就启用，不需要勾选）。行内
  /// 勾选与全选当前结果同步两套选择，选中后四项全启用。只用「勾
  /// 选当前页」时复习启用、整理 / 删除仍禁用——旧栏原样行为（旧
  /// 栏整理按钮同样只认通用选择）。
  Widget _buildBatchBar(List<Question> all) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final hasSelection = _s.selected.isNotEmpty;
    final hasReviewSelection = _s.reviewEffectiveIds().isNotEmpty;
    final menuStyle = _batchMenuStyle(palette, scale);
    final itemStyle = _batchMenuItemStyle(palette, scale);
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
      child: Row(
        children: [
          Text(
            _s.reviewSelectionLabel(),
            key: const Key('review-selection-label'),
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          SizedBox(width: 8 * scale),
          _batchMenu(
            key: const Key('batch-select-menu'),
            label: '选择',
            enabled: true,
            menuStyle: menuStyle,
            children: [
              _batchMenuItem(
                label: '全选当前结果',
                style: itemStyle,
                onPressed: () => _toggleSelectAll(all),
              ),
              _batchMenuItem(
                label: '勾选当前页',
                style: itemStyle,
                onPressed: () => _n.selectReviewPage(_reviewPageItems(all)),
              ),
              _batchMenuItem(
                label: '全选全部筛选结果',
                style: itemStyle,
                onPressed:
                    all.isNotEmpty ? _n.selectReviewAllFiltered : null,
              ),
              _batchMenuItem(
                label: '清除选择',
                style: itemStyle,
                onPressed: hasSelection || hasReviewSelection
                    ? _clearBatchSelection
                    : null,
              ),
            ],
          ),
          SizedBox(width: 8 * scale),
          _batchMenu(
            key: const Key('batch-organize-menu'),
            label: '整理',
            enabled: hasSelection,
            menuStyle: menuStyle,
            children: [
              _batchMoveFolderSubmenu(itemStyle),
              if (_s.folderId != null)
                _batchMenuItem(
                  label: '移出当前文件夹',
                  style: itemStyle,
                  onPressed: _batchMoveOut,
                ),
              _batchMenuItem(
                label: '加标签',
                style: itemStyle,
                onPressed: _batchAddTag,
              ),
              _batchMenuItem(
                label: '收藏',
                style: itemStyle,
                onPressed: _batchFavorite,
              ),
              _batchMenuItem(
                label: '归档',
                style: itemStyle,
                onPressed: _batchArchive,
              ),
            ],
          ),
          SizedBox(width: 8 * scale),
          _batchMenu(
            key: const Key('batch-review-menu'),
            label: '复习',
            enabled: true,
            menuStyle: menuStyle,
            children: [
              _batchMenuItem(
                label: '加入复习',
                style: itemStyle,
                onPressed:
                    hasReviewSelection ? _batchJoinReviewFsrs : null,
              ),
              _batchMenuItem(
                label: '全部加入复习',
                style: itemStyle,
                onPressed: all.isNotEmpty ? _batchJoinReviewFsrsAll : null,
              ),
              _batchMenuItem(
                label: '立即专项练习',
                style: itemStyle,
                onPressed:
                    hasReviewSelection ? _startPracticeFromReview : null,
              ),
              _batchMenuItem(
                label: '取消加入复习',
                style: itemStyle,
                onPressed:
                    hasSelection ? _batchCancelReviewSelected : null,
              ),
            ],
          ),
          const Spacer(),
          TapRegion(
            onTapOutside: (_) => _disarmBatchDelete(),
            child: QmButton(
              key: const Key('batch-delete'),
              label: _deleteArmed
                  ? '再点一次确认删除 ${_s.selected.length} 道'
                  : '批量删除',
              variant: QmButtonVariant.danger,
              size: QmButtonSize.small,
              onPressed: hasSelection ? _onBatchDeleteTap : null,
            ),
          ),
          SizedBox(width: 8 * scale),
          QmButton(
            label: '退出批量',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: _exitBatchMode,
          ),
        ],
      ),
    );
  }

  /// 方案 A 批量栏菜单样式：与命令面板同款——圆角、阴影、条目
  /// hover 底 accent-soft。
  MenuStyle _batchMenuStyle(AppPalette palette, double scale) {
    return MenuStyle(
      backgroundColor: WidgetStatePropertyAll(palette.surface),
      surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
      elevation: const WidgetStatePropertyAll(8),
      shadowColor: WidgetStatePropertyAll(Colors.black.withValues(alpha: 0.25)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DesignTokens.radius * scale),
        ),
      ),
      padding: WidgetStatePropertyAll(
        EdgeInsets.symmetric(vertical: 4 * scale),
      ),
    );
  }

  /// 方案 A 批量栏菜单条目样式：hover / 聚焦底 accent-soft，
  /// 禁用态 muted 字（与命令面板条目同款）。
  ButtonStyle _batchMenuItemStyle(AppPalette palette, double scale) {
    return ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return palette.accentSoft;
        }
        return Colors.transparent;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return palette.muted;
        return palette.ink;
      }),
      overlayColor: WidgetStatePropertyAll(Colors.transparent),
      padding: WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12 * scale, vertical: 8 * scale),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8 * scale),
        ),
      ),
      textStyle: WidgetStatePropertyAll(
        const TextStyle(fontSize: 13.5),
      ),
    );
  }

  /// 方案 A 批量栏菜单触发按钮（MenuAnchor + QmButton plain 小按钮）。
  Widget _batchMenu({
    required Key key,
    required String label,
    required bool enabled,
    required MenuStyle menuStyle,
    required List<Widget> children,
  }) {
    return MenuAnchor(
      key: key,
      style: menuStyle,
      menuChildren: children,
      builder: (context, controller, child) => QmButton(
        label: label,
        trailingGlyph: '▾',
        variant: QmButtonVariant.plain,
        size: QmButtonSize.small,
        onPressed: enabled
            ? () => controller.isOpen ? controller.close() : controller.open()
            : null,
      ),
    );
  }

  /// 方案 A 批量栏菜单条目：点选项即执行并关菜单（MenuItemButton
  /// 默认 closeOnActivate）。
  MenuItemButton _batchMenuItem({
    required String label,
    required ButtonStyle style,
    required VoidCallback? onPressed,
  }) {
    return MenuItemButton(
      style: style,
      onPressed: onPressed,
      child: Text(label),
    );
  }

  /// 方案 A 批量栏「移入文件夹」子菜单：文件夹选择放进点开后的
  /// 列表里（旧独立下拉删掉），点文件夹即执行移入并关菜单。
  /// 跨学科列表（无归属学科）没有可移的目标：子菜单里留一条禁用
  /// 的旧提示原文；同学科下无其他文件夹时同理留一条禁用提示。
  Widget _batchMoveFolderSubmenu(ButtonStyle itemStyle) {
    final options = _s.batchFolderOptions();
    final children = <Widget>[
      if (options.isEmpty)
        MenuItemButton(
          style: itemStyle,
          onPressed: null,
          child: Text(
            _s.subjectId == null
                ? '跨学科列表不能批量移文件夹：先打开一本书，再批量移'
                : '没有其他文件夹',
          ),
        )
      else
        for (final f in options)
          MenuItemButton(
            style: itemStyle,
            onPressed: () => _batchMoveToFolder(f.id),
            child: Text(_s.folderLabel(f)),
          ),
    ];
    return SubmenuButton(
      style: itemStyle,
      menuChildren: children,
      child: Text(_s.folderId != null ? '移入文件夹' : '加入文件夹'),
    );
  }

  /// P3 入口 1“勾选当前页”用的当页题（与 _buildList 的分页同口径）。
  List<Question> _reviewPageItems(List<Question> all) {
    final totalPages = (all.length / _s.pageSize).ceil().clamp(1, 9999);
    final page = _s.page.clamp(0, totalPages - 1);
    final start = page * _s.pageSize;
    return all.skip(start).take(_s.pageSize).toList();
  }

  Widget _buildArchivedRows(List<Question> items, List<String> orderIds) {
    final scale = qmScaleOf(context);
    const lineKind = QmRowLineKind.line;
    return Column(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) QmRowLine(kind: lineKind),
          // 二十二批 D-247：行轻微错开入场（行号 × 30ms，上限 8 行）。
          EntranceFadeSlide(
            delay: Duration(milliseconds: (i > 8 ? 8 : i) * 30),
            child: _buildArchivedRow(items[i], orderIds),
          ),
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
        await widget.onOpenDetail(
          q,
          orderIds,
          searchContext: _searchContext(),
        );
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
              onTap: () => showQuestionZoomDialog(context, q, returnLabel: '错题本'),
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
                          rowDisplayTitle(q),
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
                  _metaLine(
                    q,
                    _s.search.trim().isEmpty ? null : _s.search.trim(),
                  ),
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

  /// 分页行（十九批 A1，板子 §1.5）：右对齐、无数字页码按钮——
  /// `每页 [N▾] 道 · 第 X/Y 页　上一页　下一页`（第 X/Y 页与上一页
  /// 之间是全角空格）。每页条数下拉保留现版 10/20/30/40/50、
  /// 默认 10；上一页 / 下一页到边界置灰。
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
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
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
          Text(
            '道 · 第 ${page + 1}/$totalPages 页　',
            style: TextStyle(
              fontSize: DesignTokens.pagerFontSize,
              color: palette.muted,
            ),
          ),
          QmButton(
            label: '上一页',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: page > 0
                ? () => _n.update((st) => st.copyWith(page: page - 1))
                : null,
          ),
          SizedBox(width: 6 * scale),
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
