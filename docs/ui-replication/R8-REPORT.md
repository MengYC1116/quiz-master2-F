# R8-REPORT — 复习页重建

- 分支：`ui-replication`（基线 `0c81217242c20fa4438e04db4ebabc92f2c0ddd1`）
- 视觉基准：`~/workspace/your_files/quiz-master2-jiao-hu-yuan-xing/quiz-master2-jiao-hu-yuan-xing.html`，SHA256 `18c8c43485a7831cec22e3d4fff659d7ea39754219b391874f0c5a88f50135e1`（动手前已核对一致）
- 状态：完成并验证通过；未 commit、未 push。

## 0. 本轮起点

任务开始时复习页是基线实现（`lib/modules/review/review_page.dart` 977 行，Material 风格），与 HTML 复习页（`viewReview` / `revListHTML` / `revRunHTML` / `revSummaryHTML`，R0 附录 A）有六处结构偏差：

1. 基线按题分组，HTML 按「学科 × 错因」分组；
2. 基线会话按“题 × 错因”逐项走四步，HTML 按题分块（①② 按错因逐个走，③④ 按题走，④ 是一题全部错因同屏自查）；
3. 基线无恢复条（中途退出从中断的错因恢复），HTML 有；
4. 基线无已治愈组，HTML 有（可点开看解决记录）；
5. 基线无“还没加入复习的题”盒，HTML 有；
6. 基线排序下拉在页内，HTML 排序只在设置里。

直接按 HTML 结构重写，未接续半成品。环境工具链完好（Flutter 3.47.9 / Dart 3.13.7、Xvfb、xdotool、ImageMagick、Playwright 均在），本轮无需恢复。

## 1. 修改文件清单

| 文件 | 改动 |
|---|---|
| `lib/modules/review/review_page.dart` | 重写（977 → 1960 行）：错因治疗模型复习页（见 §3）；业务口径沿用基线（`recordSelfCheck` / `saveRemedy` / `reviewState`），不改 Schema/状态机；新增 `_CauseGroup` / `_CauseBlock` / `_ResumeInfo`，页内排序下拉已删（排序只走设置「复习列表默认排序」） |
| `lib/theme/design_tokens.dart` | 新增 R8 复习度量块 13 个常量：`reviewContentMaxWidth = 760`（HTML `.rev-wrap` 行内 760px）、`reviewMetaFontSize = 13`、`reviewStepFontSize = 12.5`、`reviewPendHeadFontSize = 12.5`、`reviewRowPaddingV/H = 10/14`、`reviewCuredMarginBottom = 16`、`reviewCuredHeadPaddingV = 9`、`reviewDetailPadding = 16`、`reviewKvLabelWidth = 76`、`reviewActsMarginTop = 16`、`reviewActsGap = 10`、`reviewRemedyFontSize = 14`；其余复用已有 token（分页器、筛选下拉、提示字号等） |
| `test/review_page_test.dart` | 新增 24 个测试（605 行，见 §4） |
| `docs/ui-replication/run-shots-r8.sh` | 新增：probe（导航 + 列表 + 会话探针）/ normal（亮/深 × 标准/大/特大 6 张）/ states（11 张状态） |
| `docs/ui-replication/run-regress-r8.sh` | 新增：首页 → 复习列表 → 开始解决 → 暂停 → 恢复条 → 回首页导航回归（5 张）；暂停会写 `review_state`，脚本结束时清掉 |
| `docs/ui-replication/shots/r8/html-shots-r8.cjs` | 新增：Playwright 截 HTML 原型复习页亮/深列表 + 会话四步（亮）+ 总结（亮），共 8 张（只截 `.win` 应用框，截图前去掉介绍头与 toast；见 §5 脚本调试记录） |
| `docs/ui-replication/shots/r8/make-compare-r8.py` | 新增：R7 脚本复制，标签字体 Noto Sans CJK（`/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc`） |
| `docs/ui-replication/shots/r8/` | 截图 43 张 PNG（22 张 Flutter + 5 张回归 + 8 张 HTML + 8 张对照图） |

未动：其他八页主体、`lib/data`、`lib/models` 的业务语义、`pubspec.lock`、数据库 Schema、`app_icon.ico`；R0 §6-B 业务问题、R7 未解决问题均未顺手改；放大浮层 1.5× 初始偏移未修（见 §6 第 2 条）。

## 2. git diffstat

R1–R8 均未提交，`git diff --stat` 为相对基线的累计值（10 个已追踪文件，+11218/−4216）。R8 直接相关的部分：

```
lib/modules/review/review_page.dart | 2217 ++++----（基线 977 行重写 → 1960 行；+1600/−617）
lib/theme/design_tokens.dart         | 未追踪新文件（R1 建；R8 加 13 个复习度量常量）
test/review_page_test.dart          | 605 行（未追踪新文件，24 个测试）
docs/ui-replication/               | 未追踪（R8 新增 run-shots-r8.sh / run-regress-r8.sh / shots/r8）
```

`lib/models/models.dart`、`lib/modules/collect|detail|home|organize|wrongbook`、`lib/theme/app_theme.dart`、`lib/widgets/widgets.dart`、`lib/app.dart` 的 diff 为 R1–R7 累计值，R8 未改动它们（`showQuestionZoomDialog` 只在复习页调用时传了 `returnLabel: '复习'`，共享实现未动）。

## 3. 结构与 token 来源

- **列表**：学科 × 错因分组（`_CauseGroup`，状态口径：全已解决 → 已解决、有待解决 → 待解决、其余 → 解决中；含复查标记），按加入时间排（排序取自 `settings.reviewSort`，**页内排序下拉已删**，与 HTML 一致）；学科 + 错因两个下拉筛选（错题本 `_styledDropdown` 同款：36 高、13.5px、line-strong 边、圆角 10、▾ 文字符号），筛选变化回第 1 页；元信息行（`待解决/解决中 N 条 · 复查 N 条 · 已解决 N 条 · 列表按加入时间排，先加入的先解决`）；分组头 `待解决错因 · 一道题有多个错因时在列表里只出现一次，一道题里挨着解决完`；分组行（学科名 800 号 subjectInk 色 + 错因粗体 + `关联 N 道题：标题1、标题2` + 复查 pill + 状态 pill + `开始解决` 小按钮）；分页器 HTML 式（`共 N 条 · 第 P / T 页` + 每页数量下拉 + 上一页/页码/下一页，默认 10，可选 10/20/30/40/50）；已治愈组 `.duelist`（头含 `已解决满 N 天会自动回到上面的列表复查`，N 取真实 `recheckIntervalDays` 设置值，不照搬 HTML 的 7；点行展开看解决于/下次复查/补救记录）；“还没加入复习的题”盒；空态用 `QmEmptyState`（小伙伴 + `复习列表还是空的` + `去错题本选题`）。列表无外层卡片框、无固定高度内滚容器，整页滚动。
- **恢复条**：`_ResumeInfo`（保存的扁平队列 `qid|cause` + 位置解析回块/错因下标）；列表顶部 detailbox `上次解决到一半 · 学科「错因」（题名），第 N / M 道题` + 继续解决（primary）/ 从头开始（secondary）；陈旧断点在 `_load()` 时校验回收（无有效待治项则清掉）。
- **会话**：按题分块 `_CauseBlock`（块内错因按题内错因顺序）；块由筛选后分组选中的题组成，每题带其全部待治错因；每会话错因数（设置 5/10/不限）在建块时按列表顺序截断；按组“开始解决”跳到首个含该组错因的块（块内仍从首个错因治起，`ci` 保持 0，与 HTML `REV2.bi = i` 一致）；范围标签：无学科筛选 → `全部待解决错因`，有 → `{学科名}这一科`。
- **四步**：① 看错因（纸面 `QuestionSlice`，点开放大浮层 `returnLabel: '复习'`；detailbox：备注/上次自查；`下一步：写补救` + `跳过该题`）；② 写补救（仅显示上次一条补救 + 提示；14px 输入框；`下一步：下个错因` / `下一步：重做` + `跳过`）；③ 重做（答案默认按设置藏/显；藏着时只有 `看答案` 主按钮；显示后 `下一步：自查` + `遮住答案`）；④ 自查（一题全部错因同屏，每错因 已解决/未解决/不确定 三档小按钮，选中变 primary；选“不确定”出提示行；全选完才启用 `下一题` / `看总结`）。
- **跳过**：按 `qid|cause` 计次，第 1 次追加单错因块到队尾，第 2 次丢弃；块空则移除，队尾耗尽则出总结。
- **暂停**：扁平队列 + 位置存 `review_state`（与基线同格式，兼容基线存的断点）；**总结**：小伙伴 + `message: '这一轮辛苦啦'` + detailbox（`今天解决了 N 个错因 · 还有 M 个未解决`，N 只计本轮新治愈的，复查通过不计；每条变化含下次复查日期 M-D 格式 + 备注文案）+ `回复习列表`。
- **错误横幅**：自查提交抛错时出 `QmBanner` error `复习记录保存失败，本次自查还没有存下。请重试，或重启应用后再复习。`并留在自查步（真实应用内无法靠常规操作触发，只在 widget 测试覆盖，见 §6 第 3 条）。
- **Token 来源**：全部颜色取自 `DesignTokens`（深色纸面 `#D8DCE2`、深色主色 `#7FA8D0`，D1/D2 已确认；复习度量见 §1）；组件全部用 UI Kit；文字符号（`▸` `▾` `←` `→` `★`）不用图标字体；缩放唯一映射 1.00/1.15/1.30，字号只在 app.dart TextScaler 处乘一次，布局尺寸按 `qmScaleOf` 乘一次，不用 Transform.scale。

## 4. 测试与构建结果

- `flutter analyze`：**No issues found!**
- `flutter test` 全量：**209/209 通过**（基线 185 + R8 新增 24）。
- `flutter build linux --release`：**成功**，产物 `build/linux/x64/release/bundle/quiz_master2`。
- Flutter/Dart 3.47.9 / 3.13.7，路径 `~/workspace/flutter-install/flutter/bin/flutter`。
- R8 新增 24 个测试（`FakeReviewRepo` 全内存覆盖 settings/all/causeRecords/reviewHistory/reviewState/saveReviewState/clearReviewState/recordSelfCheck 按真实语义/saveRemedy/saveSettings）：分组列表、元信息、无 Card/无 Icon、学科筛选、错因筛选、分页 + 筛选回第 1 页、每页数量可改、已治愈展开/收起、空态、无旧翻卡文案、四步完整流程、满 2 次治愈计数、全选完才启用下一题、跳过两次留到下次、暂停 → 恢复条 → 继续解决、按组开始、放大浮层、保存失败横幅、亮/深 × 1.00/1.15/1.30 无溢出。
- 测试编写教训（写给后续轮次）：`find.text` 匹配 `Text.rich` 是整串纯文本，拼接文本用 `textContaining`；筛选后下拉框当前值与分组行同名文本会重复计数，期望值按实际计数写；每页数量下拉的 value 不在 [10,20,30,40,50] 时 Flutter 断言失败，生产设置只会存这五档，容错分支只防脏数据（见 §5 第 2 条）。

## 5. 截图对照（Xvfb 1280×720，真实库 9 题、已加入复习 7 道、已整理且已加入的待治题 3 道）

截图目录 `docs/ui-replication/shots/r8/`（43 张 PNG：22 张 Flutter + 5 张回归 + 8 张 HTML + 8 张对照图）。HTML 原型是静态演示数据（9 道题、7 道已加入、DEMO_TODAY 2026-11-11），与真实库数字/题名/错因不同——对照只看结构/样式/文案，不逐数比对。HTML 演示库里没有“已解决且未到复查”的错因，所以 HTML 列表没有已治愈分组可展开（见 §6 第 8 条）；Flutter 已治愈图靠临时数据拍。

| 截图 | 对照结论 |
|---|---|
| `review-light/dark-standard.png` | ✓ 3 组（数学 概念不清 待解决 / 英语 概念不清 复查·已解决 / 数学 计算错误 解决中）、元信息 `待解决/解决中 2 条 · 复查 1 条 · 已解决 0 条`、分页 `共 3 条 · 第 1 / 1 页`、未加入盒（英语「图表作文」、政治「马原」）。与 HTML 结构一致；差异：HTML 标题是 `复习 · 解决错因` + 标题下有设计说明长文，Flutter 标题是 `复习` 且无说明文案（Meng 已定：设计说明块移出每页）；HTML 演示库 7 组，真实库 3 组（数字差是数据不同）。 |
| `review-light/dark-large.png`、`review-light/dark-extraLarge.png` | ✓ 三档无溢出；特大档左导航学科速览数字换两行（R6 同款既有行为）、“还没加入复习的题”盒在首屏外，需整页滚动查看（符合设计，无固定高度内滚容器）。 |
| `review-cured-collapsed-light-standard.png` / `review-cured-expanded-light-standard.png` | ✓ 已治愈组折叠/展开：展开后行变 `收起`，记录区 `解决于 2026-11-11 · 下次复查 2026-11-21（11-21）`。本组靠临时把 q-eng-1 的 `recheck_date` 改到未来拍，拍完已恢复（见 §7）。 |
| `review-resume-light-standard.png` | ✓ 恢复条：`上次解决到一半 · 数学「计算错误」（定积分阴影面积），第 1 / 2 道题` + `继续解决` / `从头开始`。断点靠临时 `INSERT INTO review_state` 制造，拍完已恢复。 |
| `review-empty-light-standard.png` | ✓ 空态：小伙伴 + `复习列表还是空的` + `去错题本选题` + 未加入盒列出 9 道题。靠临时 `UPDATE questions SET review_joined = 0` 拍，拍完已恢复。 |
| `review-session-recall-dark-standard.png` | ✓ 会话第①步：`第 1 / 3 道题 · 全部待解决错因`、四步指示 ① 激活、纸面深色 `#D8DCE2`、`下一步：写补救` + `跳过该题`。 |
| `review-session-remedy-dark-standard.png` | ✓ 写补救：上次补救一条 + 14px 输入框 + `下一步：重做`。 |
| `review-session-redo-dark-standard.png` / `review-session-redo-shown-dark-standard.png` | ✓ 重做：答案藏着时只有 `看答案` 主按钮 + 提示 `答案默认是藏着的…`；显示后 `下一步：自查` + `遮住答案`。 |
| `review-session-check-dark-standard.png` | ✓ 自查：④ 激活、单错因三档按钮、`下一题` 禁用态（未全选）。 |
| `review-summary-dark-standard.png` | ✓ 总结：小伙伴 + `这一轮辛苦啦` + `今天解决了 1 个错因 · 还有 1 个未解决` + 3 条变化含下次复查 2026-11-20 + `回复习列表`。会话流程会改 `cause_records`（q-math-1 待解决 → 解决中、q-math-3 解决中 → 已解决、q-eng-1 复查通过），靠脚本 trap 备份恢复。 |
| `review-zoom-dark-standard.png` | ✓ 放大浮层：`整题图 · 放大查看` + `150%` + 提示 `回到复习`。但纸面左偏约 60–80px（本例文字未被裁切），见下“放大浮层初始偏移”。 |
| `regress/regress-home.png`、`regress-review-list.png`、`regress-session.png`、`regress-resume.png`、`regress-back-home.png` | ✓ 首页 → 复习列表 → 开始解决（第 1 / 3 道题，① 看错因）→ 暂停 → 恢复条 → 回首页链路正常；断点已清。 |
| `html-review-light/dark.png`、`html-review-recall-light.png`、`html-review-remedy-light.png`、`html-review-redo-light.png`、`html-review-redo-shown-light.png`、`html-review-check-light.png`、`html-review-summary-light.png` | ✓ Playwright 截的 HTML 原型复习页（只截 `.win` 应用框，无介绍头、无 toast）；会话 7 块全走完出总结 `今天解决了 2 个错因 · 还有 6 个未解决`。HTML 总结“今天解决了 2 个”只计本轮新治愈（m1、m3 各满 2 次），与 Flutter 口径一致。 |
| `compare-list-light/dark.png`、`compare-recall.png`、`compare-remedy.png`、`compare-redo.png`、`compare-redo-shown.png`、`compare-check.png`、`compare-summary.png` | ✓ HTML（上）/ Flutter（下）并排对照 8 张。结构/样式/文案一致；会话与总结两张是 HTML 亮色对 Flutter 深色（Flutter 会话态只拍了深色标准档，标签已注明）。剩余差异见本表各行与 §6。 |

### 本轮测试中发现并已修的两个真问题

1. **自查文案/编码错配**：自查按钮存中文文案（`已解决`），但 `recordSelfCheck` 要 `solved`/`unsolved`/`unsure` 编码；未映射时选「已解决」会落入 else 分支被当成「未解决」。修复：在 `_finishQuestion` 内把文案映射为编码后再调用（`已解决→solved`、`未解决→unsolved`、其余→`unsure`）。widget 测试覆盖满 2 次治愈计数，回归后通过。
2. **分页下拉断言**：每页数量下拉的 value 不在 [10,20,30,40,50] 时 Flutter 断言失败。修复为容错——选项集合加入当前值再排序（生产设置只会存 10/20/30/40/50，该分支只防脏数据）。

### 截图脚本的坐标校准（教训，写给后续轮次）

- **像素扫描定位法**（R7 定下，R8 再验证）：不要凭缩放后的截图目测。初版目测坐标五次打偏：导航“复习”Y 310 打到学习报告（扫描修正为标准 271 / 大 294 / 特大 334）；写补救主按钮 (709,420) 打中输入框（扫描修正为 (696,497)）；重做 `下一步：自查` (695,630) 打空（修正为 (691,593)）；自查「已解决」 (417,299) 完全错误（修正为 (421,414)）；`下一题`/`看总结` (748,368) 错误（修正为 (748,505)）；已治愈行 (700,565) 低 6px 打在行外（修正为 (700,538)）。实测中心（标准档 1280×720）：导航复习 (100,271)、列表顶栏「开始解决」 (418,117)、三组「开始解决」 (1070,298/363/428)、会话「查看题目详情」 (771,135)、「暂停」 (865,135)、「下一步：写补救」 (691,581)、写补救步主按钮「下一步：重做」 (696,497)、「跳过该题」 (827,581)、「看答案」 (748,520)、「下一步：自查」 (691,593)、自查「已解决」 (421,414)、「下一题」/「看总结」 (748,505)、已治愈行 (700,538)。
- **HTML 截图脚本的会话驱动有三处原型行为要顺着走**（`html-shots-r8.cjs` 的循环调试记录）：① `finish-q` 之后下一块回到第①步，不是留在自查步——每轮都要把步骤推到自查；② 一题多错因时，写完一个错因的补救会回到第①步走下一个错因——内层循环一直推到自查步为止；③ 重做步答案遮着时没有 `to-check` 按钮，必须先点 `show-ans` 再点 `to-check`。三处都修后 7 块一次走完出总结。
- **Playwright 环境**：浏览器在 `~/workspace/.playwright-browsers`（`PLAYWRIGHT_BROWSERS_PATH` 须显式设；默认 `~/.cache/ms-playwright` 里没有），模块在 npx 缓存 `/home/hatch/.npm/_npx/f0a362733743bae2/node_modules`（`NODE_PATH` 指向它；playwright 1.49.1）。
- 放大浮层初始偏移（**未修**，见 §6 第 2 条）：R8 确认复习页同样受影响——1.5× 下纸面整体左偏约 60–80px（本例文字未被裁切）。与整理台/详情页同款，共享 `showQuestionZoomDialog`，R8 未动，留待另立项修。

## 6. 未解决问题

1. **Win11 字体/DPI/窗口尺寸待真机复核，Linux 结果不替代 Win11 验收。** 尤其 Linux 回退字体（Noto Serif CJK）与 Win11 的微软雅黑/等线行高度量不同，各处 11–13px 小字与标签需真机确认无裁切；1280×720 以外窗口尺寸（HTML 断点按窗口宽）也须真机复核；Windows Release 构建须在 Meng 的 Win11 机器上验证。
2. **放大浮层 1.5× 初始偏移**（R7 遗留，**R8 确认复习页同样受影响**）：复习页点题图放大时纸面整体左偏约 60–80px（本例文字未被裁切）；共享 `showQuestionZoomDialog`，动它会同时影响整理台和详情页，R8 未修，留待另立项。
3. **错误态真实截图不可触发**：复习记录保存失败横幅只在 widget 测试覆盖（FakeRepo 抛错），真实应用内无故障注入入口，故无真实窗口错误态截图。
4. **HTML 与模型/基线口径的既有缺口（R8 沿用基线，未改）**：HTML 会话「当时为什么错」无 Flutter 模型字段（未抄）；已治愈展开的「自查记录」无按错因的历史字段（Flutter `review_history` 按题不按错因，只显示了解决于/下次复查/补救记录）；HTML `qInReview` 排除已归档题，Flutter 基线复习列表包含已归档的已加入题（R8 沿用基线口径）；复查通过时 `recordSelfCheck` 会把 `solvedCount` 加到超过治愈次数（如 2→3，HTML 复查通过不加），属基线既有行为；`review_history` 的「上次自查」是按题的最近一次，不是按错因的。
5. **R0 §6-B 业务问题未动**：学习报告 `pendingCount` 不按时间范围过滤；学科管理新增学科不同步到首页/导航速览（`Subject.all` 写死三科）；设置“启动页”未被消费；通知提醒无调度实现；备份导出不含 4 张表。
6. **分页 / 真实 YOLO / 真实图片切片 / 系统拖放仍未验证**（R8 范围外既有项）；`CompactSliceThumb` 仍白色（R7 已知，与 QuestionSlice 纸面改动不一致）。
7. **列表排序入口变化**（需说明）：基线页内有排序下拉，R8 按 HTML 删掉，排序只走设置「复习列表默认排序」（默认按加入时间）；元信息行显示当前排序口径。
8. **会话内容范围变化**（需说明）：基线会话按筛选后的“题 × 错因”逐项走四步；R8 按 HTML 改为按题分块（①② 按错因、③④ 按题），块内含该题全部待治错因，筛选只决定进会话的题集；按组开始跳到首个含该错因的块（块内仍从首个错因治起）。
9. **空态取舍**（需说明）：HTML 正常态下无数据时显示 detailbox `现在没有待解决的错因……`；R8 在待治 + 已治愈都为空时改用小伙伴空状态（原型 `state==='empty'` 的形态）+ 未加入盒；有已治愈无待治时仍显示 detailbox 提示（与 HTML 一致）。
10. **HTML 演示库无已治愈分组**：原型演示数据里唯一的已解决错因（政治 p1 概念不清）复查日正好是 DEMO_TODAY 当天，算复查项不算已治愈，所以 HTML 列表里没有可展开的已治愈分组；已治愈展开只有 Flutter 单侧截图，无 HTML 对照。
11. **左导航学科速览数字换行**（R6 §6.6 同款既有行为，非 R8 引入）；标题 `复习` vs HTML `复习 · 解决错因`（见 §5）。

## 7. 验收后状态

- 真实库已恢复原状：9 道题、已加入复习 7 道、待治 3 道（q-math-1 概念不清 pending / q-math-3 计算错误 inProgress ok=1 / q-eng-1 概念不清 solved 复查日 2026-11-11），`review_state` 为空，`themeMode=dark`、`fontSize=standard`；截图备份 `.qm2-r8-backup.db` 已删除；临时改的 q-eng-1 复查日、临时插的断点、临时清的 `review_joined` 均已随备份恢复；回归脚本的断点已清。
- 未 commit、未 push。
