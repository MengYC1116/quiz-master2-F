# R6-REPORT — 错题本重建

- 分支：`ui-replication`（基线 `0c81217242c20fa4438e04db4ebabc92f2c0ddd1`）
- 视觉基准：`~/workspace/your_files/quiz-master2-jiao-hu-yuan-xing/quiz-master2-jiao-hu-yuan-xing.html`，SHA256 `18c8c43485a7831cec22e3d4fff659d7ea39754219b391874f0c5a88f50135e1`（已核对一致）
- 状态：完成并验证通过；未 commit、未 push。

## 0. 接续半成品（本轮起点）

任务开始时 `lib/modules/wrongbook/wrongbook_page.dart` 已有大量未完成改动（3508 行，`flutter analyze` 0 问题），无 `R6-REPORT.md`、无 r6 截图。检查结论：半成品结构完整、可接续，未推倒重写。

- `flutter test test/wrongbook_page_test.dart` 接续时 23 通过 / 10 失败，失败集中在列表页 / 批量 / 分页。逐条核对 HTML 原型后判定：**实现多处贴合 HTML，测试期望有误**；另有 2 处实现小问题（见下）。
- 实现侧改动（本轮接续时，2 处）：
  1. 批量条“全选当前结果”文案改为可点：抽出 `_toggleSelectAll(List<Question> all)`，复选框 `onChanged` 与文案 `GestureDetector.onTap` 共用（原来点文案无反应，批量测试因此失败）。
  2. 截图对照后修 `_folderCount` 口径（见 §5 第二条）。
- 测试侧修正（8 处，均有 HTML / 规范依据）：
  1. 紧凑行明细行用 `find.textContaining(..., findRichText: true)`（该 finder 默认不匹配独立 RichText，系 flutter_test 行为）。
  2. 搜索测试新增 `plainText(String s)` helper（只匹配普通 Text，不匹配搜索框 EditableText），用于查询词与行标题同文时的断言。
  3. 筛选按钮 0 项：期望由 `筛选（已选 0）` 改为 `筛选 ▴`（面板已打开；HTML 只在有已选时才显示计数）。
  4. 筛选按钮 1 项：期望由精确 `筛选（已选 1）` 改为 `find.textContaining('筛选（已选 1）')`（实际文案含箭头 `筛选（已选 1） ▴`）。
  5. 两处测试漏 `pumpWrongbook`：补上——“筛选：错因状态‘已解决’才显示已掌握题”、“筛选：收集时间‘最近一周’排除 10 天前的题”。
  6. 归档视图：期望由 `返回题目列表` 改为 `← 返回题目列表`（与 HTML 一致）。
  7. 分页测试第 1 页：期望由 `12` 改为 `9`（每页 10、序号按页重编号，第 1 页只有 1–10；`10` 会同时命中每页下拉的显示值，故用 `9` 校验懒加载建卡）。
  8. 紧凑行复查日期：期望由 `—` 改为 `下次复查 —`（实现文本为整串 `下次复查 —`）。
  9. 20 条/页分页测试：一次大 drag 改为 `dragUntilVisible(find.text('12'), find.byType(ListView), Offset(0,-300))`（12 张卡时一次 drag 不一定触底）。
  10. 新增“错误态占位”测试组：`QuestionSlice(failed: true)` 显示学科图标 `数` + `数学 · 极限题`、无 Icon（数学科 icon 是 `数`；应用内暂无真实图片通道，失败占位无应用级触发入口，见 §6）。
- 本轮还新增 1 个测试（§4）：“选择模式：点「全部题目」仍进列表（与 HTML 一致，全部题目不可选）”。

## 1. 修改文件清单

| 文件 | 改动 |
|---|---|
| `lib/modules/wrongbook/wrongbook_page.dart` | 接续半成品完成重建（3508 → 3526 行）：书架 / 目录 / 列表三视图（见 §3）；本轮增量：`_toggleSelectAll`、`_folderCount` 口径、列表工具栏宽度 340/210 → 280/200（见 §5） |
| `test/wrongbook_page_test.dart` | 35 个测试（见 §4）；含上轮 10 失败的修正、失败占位组、选择模式全部题目组；`q6 未整理题` 挂上文件夹 `f2`（验证目录计数不算未整理题，见 §5） |
| `docs/ui-replication/run-shots-r6.sh` | 新增：normal（亮/深 × 标准/大/特大 6 张）/ directory（4 张）/ list（4 张）/ states（9 张状态） |
| `docs/ui-replication/run-regress-r6.sh` | 新增：首页 → 错题本书架 → 数学书目录 → 全部题目列表 → 回首页导航回归（5 张） |
| `docs/ui-replication/shots/r6/html-shots-r6.cjs` | 新增：Playwright 截 HTML 原型三视图亮/深 6 张（只截 `.win` 应用框，截图前去掉复查提醒 toast） |
| `docs/ui-replication/shots/r6/make-compare-r6.py` | 新增：PIL 竖排合成 HTML / Flutter 并排对照图（HTML 在上、Flutter 在下，中间 34px 标签条，深蓝底白字；标签用 ASCII，PIL 默认字体画不出中文） |
| `docs/ui-replication/shots/r6/` | 截图 40 张（23 张 Flutter + 5 张回归 + 6 张 HTML + 6 张对照图） |

未动：其他八页、`lib/data`、`lib/services`、`lib/models` 的业务语义、`pubspec.lock`、数据库 Schema、`app_icon.ico`；R0 §6-B 业务问题、R5 未解决问题均未顺手改。

## 2. git diffstat

R1–R6 均未提交，`git diff --stat` 为相对基线的累计值。R6 直接相关的部分：

```
lib/modules/wrongbook/wrongbook_page.dart | 3925 ++++----（2828+/1097-，含上轮半成品的整页重写与本轮增量）
test/wrongbook_page_test.dart             | 1017 行（未追踪新文件）
docs/ui-replication/                     | 未追踪（R6 新增 run-shots-r6.sh / run-regress-r6.sh / shots/r6）
```

`lib/app.dart`、`lib/models/models.dart`、`lib/modules/collect|home|organize`、`lib/theme/app_theme.dart`、`lib/widgets/widgets.dart` 的 diff 为 R1–R5 累计值，R6 未改动它们。

## 3. 结构与 token 来源

- **书架 `_buildShelf`**：页头（24px/800 + 副标题 `一科一本错题本，点一本打开看这一科的错题。`）→ 已归档芯片 `已归档（N）` + 说明 `归档的题不在书里，点这里看归档列表、能恢复回错题本` → 书封 Grid（每页最多 6 本，每行 3 本；6 样式 × 7 封面色，学科色与封面色分离，R1 已定）→ 封面：英文科目名 + 中文科目名 + `错 题 本` + 折角 + 计数牌（题数 / 要复习 / 待复查）+ `开始复习` → 分页器 `← 上一页 1 下一页 → 第 1 / 1 页 · 共 3 本（每页最多 6 本）`。已归档视图：标题 `已归档` + `N 道题` + 归档行（缩略图 + 标题 + `已归档` pill + `恢复到错题本`）+ `← 返回书架`。
- **目录 `_buildDirectory`**：页头 `学科 · 错题本` + `返回书架` → 工具行（搜索文件夹 / 新文件夹名称 + `加文件夹` / `选择文件夹`）→ 纸面：`全部题目` 行（加粗，计数只收已整理且未归档，见 §5）→ 文件夹树（顶层在上、子文件夹缩进在父行下，`N 个子文件夹`；展开块 `▸`/`▾` 只在有子文件夹时出现；展开状态不记住，每次进目录都先收起）→ 每行：名 + 题数（含子文件夹，0 也显示）+ `›` + 拖拽手柄 `⋮⋮` + `改名` / `删除`。删除确认是内联条（工具行与纸面之间）：`删除这个文件夹会删掉其中 N 道题（只在这个文件夹里的），确定吗？` + `要删的是学科的文件夹「名」，只删这一科的，其他科目的同名文件夹不受影响。` + `确认删除` / `取消`。选择移动模式：选择条（`已选 N 个文件夹` + 移到目标下拉 + `移动` / `退出选择` + 提示 `移动时里面的题跟着一起走；不能移到自己下面；带子文件夹的一级文件夹不能再放进别的文件夹（只留一层）`）+ 每行复选框；点行 = 勾选（`全部题目` 不可勾选，点它仍进列表，与 HTML 一致，见 §5）。
- **列表 `_buildList`**：页头 `学科 · 错题本` + `← 目录` / `合上 ✕` + 副标题 `这一科的题目列表，点一道题进题目详情；筛选里没有文件夹，文件夹在目录页选。` → 工具栏（Wrap，标准档一行）：搜索框（hint `按题名 / 文件夹 / 标签 / 学科 / 试卷 / 日期查找`，只匹配元数据，不搜题干）+ `筛选 ▾` / `重置` + 排序下拉（默认 `时间 新 → 旧`）+ `✓ 大卡片` / `紧凑列表` + `批量操作`。筛选面板 D 折叠式：4 个下拉（试卷（来源）/ 错误类型 / 收集时间 / 错因状态，**无学科/文件夹下拉**）+ 标签行（`#易错` `#常考` `#需重做`）+ 只看行（仅收藏 / 仅逾期 / 已归档）+ `收起筛选`；有已选项时筛选按钮带 `（已选 N）`，0 项不带。`重置` 清搜索、全部筛选、排序回时间新→旧、列表回全部题目。
- **大卡片**：一题一行 + 序号圆盘（随排序/筛选/分页重编号）；`>2 张内滚 2.5 张` 的内滚容器（`SingleChildScrollView` + `ConstrainedBox`）；卡片内为 `QuestionSlice`（失败占位：学科图标 + `学科 · 题型`，见 §0）；卡片下方元数据行（题名 / 错误类型 / 标签 / 错因状态 pill / 下次复查 / 收藏星）。**紧凑列表**：一行一题（缩略图 + 题名 + 明细行 `学科 · 错误类型：… · 标签：…`，学科名着学科色 + pill + `下次复查 —` + 收藏星）。
- **批量模式**：批量条（`全选当前结果` 复选框 + 文案可点 + `已选 N 道` + 批量加标签 / 试卷下拉 / 批量加入文件夹 / 批量收藏 / 批量归档 / 批量删除 / 清除选择 / 退出批量）；批量删除二次确认 `删了就没了，确定吗？`；卡片/行出现复选框；退出批量清空选择。
- **分页**：底部分页器 `共 N 道 · 第 X / Y 页 每页 [10 ▾] 道` + `上一页` / `下一页`；每页可选 10/20/30/40/50，默认 10；筛选改动回第 1 页。空状态：搜不到 `没找到这道题，换个词试试` + `清除全部筛选`；书架空（题数全 0）时书封仍显示、计数全 0。
- **业务语义沿用基线**：非归档列表只收已整理题；默认不显示已掌握（错因状态筛 `已解决` 才显示）；收藏星内联切换；文件夹按学科分、子文件夹只一层；拖拽移动（拖到文件夹上 = 移进去、拖到两个文件夹之间 = 换顺序、拖到 `全部题目` 上 = 移回顶层）；删除文件夹只删只在该文件夹里的题（另有 `_folderDeleteCount`，与目录计数口径分开，见 §5）。
- **Token 来源**：全部颜色取自 `DesignTokens`（深色纸面 `#D8DCE2`、深色主色 `#7FA8D0`，D1/D2 已确认）；组件全部用 UI Kit；文字符号（`▸` `▾` `›` `←` `✓` `⋮⋮`）不用图标字体；缩放唯一映射 1.00/1.15/1.30，字号只在 app.dart TextScaler 处乘一次，布局尺寸按 `qmScaleOf` 乘一次，不用 Transform.scale。

## 4. 测试与构建结果

- `flutter analyze`：**No issues found!**
- `flutter test` 全量：**161/161 通过**（R1–R5 的 126 个 + R6 新增 35 个）。
- `flutter build linux --release`：**成功**，产物 `build/linux/x64/release/bundle/quiz_master2`（构建前须 `rm -rf build/linux` 清旧 CMakeCache，R0 已知问题）。
- Flutter/Dart 3.47.9 / 3.13.7，路径 `~/workspace/flutter-install/flutter/bin/flutter`。
- R6 新增 35 个测试覆盖：书架（6 样式 × 7 封面色、计数牌、已归档入口、分页器、空库 0 道题）、目录（全部题目计数、文件夹树展开/收起不记住、搜索只匹配文件夹名且搜子文件夹自动展开父级、内联新建/改名/删除带数确认、选择移动禁则与取消清空、删除文件夹只删独占题）、列表（大卡片一题一行 + 序号按页重编号、>2 张内滚、紧凑列表、搜索只匹配元数据、筛选四下拉无学科/文件夹、筛选已选计数、重置、排序、批量条/全选/批量删除确认、分页 10/20/30/40/50 与换页、已归档视图、失败占位、亮/深 × 1.00/1.15/1.30 无溢出）。

## 5. 截图对照（Xvfb 1280×720，真实库 9 题、待整理 4 道）

截图目录 `docs/ui-replication/shots/r6/`（40 张：23 张 Flutter + 5 张回归 + 6 张 HTML + 6 张对照图）。HTML 原型是静态演示数据（9 道题全已整理、DEMO_TODAY 2026-11-11），与真实库数字不同——对照只看结构/样式/文案，不逐数比对。

| 截图 | 对照结论 |
|---|---|
| `wrongbook-shelf-light/dark-standard.png` | ✓ 三本书（数学蓝/英语绿/政治红，含 MATHEMATICS/ENGLISH/POLITICS 与竖排“错题本”与折角），计数牌数学 2/2/0、英语 2/0/1、政治 1/0/0，分页器 `第 1 / 1 页 · 共 3 本（每页最多 6 本）`，已归档（0）。与 HTML 结构一致，数字差只因演示数据与真实库不同。 |
| `wrongbook-shelf-light/dark-large.png`、`wrongbook-shelf-light/dark-extraLarge.png` | ✓ 三档无溢出；特大档书封更高、分页器在视口下方（整页可滚）。 |
| `wrongbook-directory-light/dark-standard.png` | ✓ 全部题目 2 道题、试卷 1、平时作业 0、模拟卷 1；工具行、改名/删除、拖拽手柄齐全。平时作业 0 道题是 §5 第二条修复后的正确值。 |
| `wrongbook-directory-light-large.png`、`wrongbook-directory-dark-extraLarge.png` | ✓ 三档无溢出；特大档左导航底部需滚动才见设置按钮（R2 外壳既有行为，见 §6）。 |
| `wrongbook-list-light/dark-standard.png` | ✓ 工具栏单行（修后，见 §5 第三条）、2 张大卡片 + 序号圆盘 1/2、分页器 `共 2 道 · 第 1 / 1 页 每页 10 道`。 |
| `wrongbook-list-light-large.png`、`wrongbook-list-dark-extraLarge.png` | ✓ 三档无溢出；大/特大档工具栏换行（HTML flex-wrap 一致）；特大档第二张卡在视口下方（整页可滚）。 |
| `wrongbook-directory-expanded-dark-standard.png` | ✓ 临时插的子文件夹“期中试卷”：试卷行 `▾` + `1 个子文件夹 1 道题`，子行 `期中试卷 0 道题`。真实库暂无子文件夹，展开态靠此临时数据 + widget 测试覆盖。 |
| `wrongbook-list-filter-light-standard.png` | ✓ 筛选面板打开：4 下拉（试卷/错误类型/收集时间/错因状态）+ 标签 `#易错/#常考/#需重做` + 只看（仅收藏/仅逾期/已归档）+ `收起筛选`；无学科/文件夹下拉。 |
| `wrongbook-list-batch-dark-standard.png` | ✓ 批量条：`全选当前结果` 已勾 + `已选 2 道` + 批量加标签/试卷下拉/批量加入文件夹/批量收藏/批量归档/批量删除/清除选择/退出批量；两张卡复选框已勾。 |
| `wrongbook-list-compact-light-standard.png` | ✓ 紧凑行：缩略图 + 题名 + 明细行（学科名着学科色）+ pill（`计算错误·解决中` / `概念不清·待解决`）+ `下次复查 —` + 收藏星（☆/★）。 |
| `wrongbook-archived-light-standard.png` | ✓ 已归档视图：`1 道题`，函数极限行 + `已归档` pill + `恢复到错题本`。 |
| `wrongbook-directory-delete-dark-standard.png` | ✓ 删除内联确认：`删除这个文件夹会删掉其中 1 道题（只在这个文件夹里的），确定吗？` + `要删的是数学的文件夹「试卷」，只删这一科的，其他科目的同名文件夹不受影响。` + `确认删除` / `取消`。 |
| `wrongbook-directory-select-dark-standard.png` | ✓ 选择条：`已选 1 个文件夹` + `移到顶层（成为一级文件夹）` + `移动` / `退出选择` + 提示文案；试卷行已勾，其余未勾。 |
| `wrongbook-list-empty-light-standard.png` | ✓ 搜 `zzzz` 无结果：`没找到这道题，换个词试试` + `清除全部筛选`。 |
| `wrongbook-shelf-empty-dark-standard.png` | ✓ 题数归零后书封仍显示、计数全 0、无崩溃。 |
| `regress/nav-home.png`、`nav-wrongbook-shelf.png`、`nav-wrongbook-directory.png`、`nav-wrongbook-list.png`、`nav-back-home.png` | ✓ 首页 → 书架 → 目录 → 列表 → 回首页切换正常；回首页后“继续上次：整理工作台 · 数学「函数极限」”正常，首页计数不变（3 道要复习）。 |
| `html-shelf/directory/list-light/dark.png` | ✓ Playwright 截的 HTML 原型三视图亮/深（只截 `.win` 应用框，无介绍头、无复查提醒 toast）。 |
| `compare-shelf/directory/list-light/dark.png` | ✓ HTML（上）/ Flutter（下）并排对照 6 张。结构/样式/文案一致；差异只剩：数字（演示数据 vs 真实库）、HTML 页内的设计说明段落（D5：不抄进应用）、HTML 左导航无图标（R2 外壳既有）、题图绘制为已知近似（R5 §6.2 同款）。 |

### 本轮截图发现并已修的三个真问题

1. **“全部题目”点击坐标打偏，列表截图初版全是目录页**：脚本初版点 (500,255)，实际行中心在 y≈318（标准档），点落在纸面上沿空白处。修复：`all_row_xy` 改 (500,310)，三档通用（行高 45–60px）；回归脚本同步改。重拍后 4 张列表图正确。
2. **目录文件夹计数含未整理题，行数与点进去的列表不一致**：基线 `_folderCount` 只排除已归档，未排除未整理。真实库 q-math-2（导数应用综合）未整理但已挂 `平时作业`，目录行写 `1 道题`，点进去列表却是空的（列表只收已整理题，R0 §5.5 口径）。修复：`_folderCount` 补 `q.isOrganized &&`，与 `_buildAllRow` 和列表同一口径；删文件夹的计数另有 `_folderDeleteCount`（删的是题本身，不跟这条口径），未动。测试：`q6 未整理题` 挂上文件夹 `f2`，目录测试的 `平时作业 1 道题` 断言现在真实覆盖这条规则。重拍后目录 `平时作业 0 道题`，与列表一致。
3. **列表工具栏在标准档换两行，HTML 是单行**：初版搜索框 340px + 排序下拉 210px，总宽约 1063px > 内容宽 1004px，`批量操作` 被 Wrap 到第二行。修复：搜索框 340→280、排序下拉 210→200（大/特大档仍换行，HTML flex-wrap 一致）。重拍后亮/深标准档工具栏单行，对照图已更新。

### 截图脚本的坐标校准（教训，写给后续轮次）

- 目录展开 `▸`：初版 (300,300) 打中了 `全部题目` 行（意外进了列表）；实测展开块在 (313,377)（`tocExpandWidth` 38）。真实库无子文件夹时 `▸` 不渲染，展开截图改用临时插的子文件夹，拍完立即恢复库。
- 删除按钮：初版 (1150,378) 落在 `改名` 与 `删除` 之间的缝隙；实测中心 (1185,377)。
- 选择移动：点 `选择文件夹` 后选择条出现，各行下移约 68px，`试卷` 行由 (500,377) 移到 (500,445)；初版按未下移的坐标点中了 `全部题目` 行——它在选择模式下仍进列表（见下一点），截图成了列表页。
- 选择模式下点 `全部题目` 仍进列表：不是 bug——HTML 的 `data-nb-tocall` 处理器也没有 `tocSelMode` 守卫（文件夹行处理器有），Flutter 与 HTML 一致；已加 widget 测试锁定。
- 批量条全选：点 `批量操作` 后批量条出现、卡片下移，初版第二点 (300,265) 落在批量条的 `全选当前结果` 上（不是首张卡复选框），结果是 `已选 2 道`——状态本身有效，脚本注释已按实际改写。
- 已归档芯片：初版 (330,125) 打在副标题与芯片之间；实测中心 (278,178)。
- 列表搜索框：初版 (420,185) 在工具栏两行之间打空；实测 (445,162)。`xdotool type` 在 C locale 下打不了中文，搜不到改用 ASCII `zzzz`，`type_text` 加 `LC_ALL=C.UTF-8`。
- HTML 截图脚本：初版选择器 `.proto-head` 不存在（介绍头是 `.ahead`，状态条是 `.proto-bar`，节标题是 `.st`/`.sd`），且整页截图含介绍头、复查提醒 toast 遮挡内容。修复：隐藏 `.ahead, .st, .sd, .proto-bar`，只截 `.win` 元素，截图前去掉 `#toast`。对照图标签改 ASCII（PIL 默认字体画不出中文，初版标签是乱码）。

### 环境恢复（过程记录，VM/服务曾重启，系统级改动丢失过两次）

- `/tmp` 被清空，`/usr/local/bin/ninja`、apt 装的 `xdotool`/`imagemagick`/`clang`/GTK 开发包全部丢失；`~/workspace`（代码、构建产物、真实库）完好。
- 恢复：`apt-get update` 后装 `libegl1 libgl1 libgles2 xdotool imagemagick ninja-build clang` 及 GTK 依赖链。`libgtk-3-dev` 仍被 `libzstd-dev` 依赖冲突卡住（`libzstd1` 已装 `1.5.5+dfsg2-2build1.1+hatch1`，而 `libzstd-dev` 要求 `= 1.5.5+dfsg2-2build1.1`），沿用 R0 的 D-21 办法：`apt-get download libgtk-3-dev libgdk-pixbuf-2.0-dev libtiff-dev libzstd-dev` 后 `dpkg-deb -x <deb> /`（目标是 `/` 不是 `/usr`，因 deb 内路径已含 `./usr/` 前缀）。
- 构建失败另有一条根因：flutter_tools 的 `build_linux.dart:197` 强制环境 `{'CC': 'clang', 'CXX': 'clang++'}`，必须装 clang，`CXX=g++` 覆盖无效；另一次失败是缺 `libEGL.so.1`（装 `libegl1`）与 `libGLESv2.so.2`（装 `libgles2`）导致应用启动 abort。
- 截图工具：`xdotool`/`import`（ImageMagick）已恢复；另备有 `~/workspace/.venv-shot/`（venv，`--system-site-packages`，已装 `python-xlib`）与 `~/workspace/.venv-shot/xshot.py`（X11 截图/点击小工具），本次未用上，仅作备用。

## 6. 未解决问题

1. **Win11 字体/DPI/窗口尺寸待真机复核，Linux 结果不替代 Win11 验收。** 尤其 Linux 回退字体（Noto Serif CJK）与 Win11 的微软雅黑/等线行高度量不同，各处 11px 小字与标签需真机确认无裁切；1280×720 以外窗口尺寸（HTML 断点按窗口宽）也须真机复核。
2. **`QuestionSlice(failed: true)` 图加载失败占位在应用内无触发入口**（无真实图片通道），只在组件级验证；与 R5 `imageFailed` 开关同款情况。
3. **R0 §6-B 业务问题**（报告范围口径、新增学科不同步、启动页未生效、通知/备份不完整）未动。
4. **区域推导为已知近似**（R5 §6.2 遗留）：真实 YOLO 第 2 层接入后以模型框为准。
5. **分页未在真实大数据量下验证**：真实库每科只有 2–3 道已整理题，分页（10/20/30/40/50）只在 widget 测试（12 道假题）里覆盖翻页与序号重编号。
6. **左导航学科速览数字换行**：`待整理 1 · 待复习 2` 在 216px 宽导航里折成两行；R2 外壳既有行为，非 R6 引入。特大档左导航底部需滚动才见设置按钮（同 R5 §6.8）。
7. **批量删除/归档/收藏等写操作只在 widget 测试里覆盖**（FakeWrongbookRepo），真实库截图流程只做读操作与一次临时归档（已恢复），未在真实库上实际执行删除。

## 7. 验收后状态

- 真实库已恢复原状：9 道题、待整理 4 道、已归档 0 道、文件夹 9 个，`themeMode=dark`、`fontSize=standard`；截图备份 `.qm2-r6-backup.db` 已删除；临时子文件夹“期中试卷”已随备份恢复删除。
- 未 commit、未 push。
