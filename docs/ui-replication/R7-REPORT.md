# R7-REPORT — 题目详情页重建

- 分支：`ui-replication`（基线 `0c81217242c20fa4438e04db4ebabc92f2c0ddd1`）
- 视觉基准：`~/workspace/your_files/quiz-master2-jiao-hu-yuan-xing/quiz-master2-jiao-hu-yuan-xing.html`，SHA256 `18c8c43485a7831cec22e3d4fff659d7ea39754219b391874f0c5a88f50135e1`（动手前已核对一致）
- 状态：完成并验证通过；未 commit、未 push。

## 0. 本轮起点

任务开始时详情页是基线实现（`lib/modules/detail/question_detail_page.dart` 1080 行，Material AppBar/Card/Icons + AlertDialog 确认），无 R7 改动、无 r7 截图。直接按方案 2 分段折叠式重写，未接续半成品。环境工具链完好（Flutter 3.47.9 / Dart 3.13.7、Xvfb、xdotool、ImageMagick、Playwright 均在），本轮无需恢复。

## 1. 修改文件清单

| 文件 | 改动 |
|---|---|
| `lib/modules/detail/question_detail_page.dart` | 重写（1080 → 1737 行）：方案 2 分段折叠式详情页（见 §3）；业务逻辑沿用基线（`_load` / `_saveEdit` / `_toggleFavorite` / `_toggleArchive` / `_doDelete` / `_goTo` / `_toggleReviewJoined` / 内联新建文件夹·知识点·标签·试卷·自定义错因）；新增构造参数 `sourceLabel`（默认 `'错题本'`）、`imageFailed`（仅测试/截图用，应用内不传） |
| `lib/theme/design_tokens.dart` | 新增 R7 详情度量块：`detailContentMaxWidth = 1004`（1280 − 内容边距 30×2；详情是推送全窗页、无左导航，宽度与 HTML `.main` 内容区一致）、`detailStarFontSize = 23`、字段标签 12.5 / 值 14.5、表单网格 gap 14×20、操作区 margin-top 22 / padding-top 18、提示 12、复习记录 13、三段间距 14、确认框 padding 12×14 |
| `lib/widgets/widgets.dart` | `showQuestionZoomDialog` 加可选 `returnLabel`（默认 `'整理台'`，详情页传 `'题目详情'`，其余调用方不动）；**QuestionSlice 纸面改 `palette.paper`（亮 `#FFFDF4` / 深 `#D8DCE2`）与 `paperLine`**，替代写死的白底 `#FFFFFF` / 边 `#DCE6F5`——R7 深色纸面（D1）要求；副作用见 §5（错题本大卡片与整理台切片深色下同步变 `#D8DCE2`，更接近 HTML）。`CompactSliceThumb` 刻意未动，仍白色（见 §6） |
| `lib/app.dart` | `_openDetail` 加可选命名参数 `sourceLabel`（默认 `'错题本'`），调用处只改闭包：整理工作台 → `'整理工作台'`、错题本 → `'错题本'`、复习 → `'复习'`；其余页面主体未动 |
| `test/detail_page_test.dart` | 新增 24 个测试（614 行，见 §4） |
| `docs/ui-replication/run-shots-r7.sh` | 新增：probe（列表 + 详情探针）/ normal（亮/深 × 标准/大/特大 6 张）/ states（8 张状态） |
| `docs/ui-replication/run-regress-r7.sh` | 新增：首页 → 错题本书架 → 数学书目录 → 全部题目列表 → 详情页 → 返回列表 → 回首页导航回归（7 张） |
| `docs/ui-replication/shots/r7/html-shots-r7.cjs` | 新增：Playwright 截 HTML 原型详情页亮/深默认态 + 答案展开（亮）+ 信息展开（深）+ 复习展开（亮）+ 编辑态（亮），共 6 张（只截 `.win` 应用框，截图前去掉复查提醒 toast；见 §5 导航教训） |
| `docs/ui-replication/shots/r7/make-compare-r7.py` | 新增：R6 脚本复制，标签条改 Noto Sans CJK（R6 的 PIL 默认字体画不出中文，标签是 tofu 方块；本轮已修，见 §5） |
| `docs/ui-replication/shots/r7/` | 截图 35 张 PNG（14 张 Flutter + 7 张回归 + 6 张 HTML + 6 张对照图 + 2 张探针） |

未动：其他八页主体、`lib/data`、`lib/models` 的业务语义、`pubspec.lock`、数据库 Schema、`app_icon.ico`；R0 §6-B 业务问题、R5/R6 未解决问题均未顺手改。

## 2. git diffstat

R1–R7 均未提交，`git diff --stat` 为相对基线的累计值（9 个已追踪文件，+9618/−3599）。R7 直接相关的部分：

```
lib/modules/detail/question_detail_page.dart | 1661 ++++----（基线 1080 行重写 → 1737 行）
lib/widgets/widgets.dart                     | 499 ++++----（R1–R7 累计；R7 只动 zoom returnLabel 与 QuestionSlice 纸面两处）
lib/app.dart                                 | 308 ++++----（R1–R7 累计；R7 只动 _openDetail sourceLabel）
lib/theme/design_tokens.dart                 | 未追踪新文件（R1 建；R7 加 11 个详情度量常量）
test/detail_page_test.dart                  | 614 行（未追踪新文件）
docs/ui-replication/                       | 未追踪（R7 新增 run-shots-r7.sh / run-regress-r7.sh / shots/r7）
```

`lib/models/models.dart`、`lib/modules/collect|home|organize|wrongbook`、`lib/theme/app_theme.dart` 的 diff 为 R1–R6 累计值，R7 未改动它们。

## 3. 结构与 token 来源

- **工具栏**：`← 返回{来源}`（QmButton plain 小）+ `第 N / M 题 · 按{来源}当前的顺序`（13px muted）+ 右侧 `编辑`（编辑态：`保存` primary + `取消`）。来源由 `sourceLabel` 传入（整理工作台 / 错题本 / 复习），返回回来源页。
- **标题**：`学科 · 题型｜题名`（24px/800）+ 文本星 `★`/`☆`（23px，收藏时金色 `paperStarOn`，Tooltip）；编辑态标题换成题名 TextField（基线功能保留；HTML 编辑表单无题名栏，见 §6）。
- **副标题**（Wrap）：`学科：{名}（只显示，不能改——导入时选定，详情和整理台都不能改）· 其他字段点右上角「编辑」改，点「保存」才生效 · 错因：{cause} · [状态 pill]`；无错因时 `错因：还没填错误类型`；已归档另有 pill。HTML 的“选错自己承担”未照搬（任务要求，用中性文案）。与 HTML 的一处差异：HTML 副标题错因状态是纯文本，Flutter 渲染为状态 pill（与应用内 pill 用法一致），且副标题较长时在标准档换两行（见 §5）。
- **横幅**：已归档 warn 横幅；空文本 warn 横幅（答案 + 解析 + 备注全空、仅查看态）；图片失败 error 横幅（文案含来源名）。图片失败占位：学科图标 + `学科 · 题型`（`imageFailed` 构造参数触发，应用内无真实图片通道，见 §6）。
- **纸面**：`QuestionSlice(maxHeight: 320, onTap: _showZoom)`，点击放大浮层（150% 起，滚轮缩放、拖动查看、点图/点关闭/Esc 回详情，浮层提示写 `回到题目详情`）；无第 2 层高亮；下方 12px 提示行（HTML flip-hint 文案）。
- **三段折叠**（`QmFoldSection(variant: detail)`，默认全折叠，进页与 `_goTo` 后复位，段间距 14×scale）：
  - **答案解析**（查看态）：`看答案` primary 按钮 + 提示 `答案和解析默认藏起来，先自己想，再点开看`；点开后两列表单网格 答案/解析（空显示可点 `待补充 · 点这里补` pill，进编辑并展开三段）+ `收起答案`。编辑态只显示提示 `正在编辑：答案和解析在下方「题目信息」的编辑表单里改…`（HTML 行为；答案/解析字段在信息编辑表单里）。
  - **题目信息**（查看态）：两列 `_formGrid`——学科（不能改）+ 提示、文件夹（归类）、知识点（`学科 › 点`，多点用 `；` 连接）、错误类型、标签（`#x #y`）、备注（笔记）、来源（全宽：`来自试卷：{名或未归属试卷}` / `收集时间：{日期}`；无“收集文件”行——无模型字段，见 §6）。编辑态：warn 横幅（`正在编辑这道题：改动先不生效…学科不在编辑范围里。`）+ 学科只读 + 试卷下拉（有日期时显示 `名（date）`）+ 新建 + QmChip 多选（文件夹 / 知识点 / 错误类型（固定枚举 + 可删自定义）/ 标签，各带 ＋新建按钮 + HTML 提示文案）+ 答案/解析/备注 TextField；取消询问内联确认框放在表单末尾。
  - **复习记录**：表单网格——复习（按 HTML `detailJoinRevHTML`：已加入 → 信息 pill `已加入复习 · 还有 N 个错因未解决` / `…错因已全部解决，满 7 天自动回来复查` + plain 小 `取消加入复习` + 提示；未加入 → primary 小 `加入复习` + 提示（含无错因后缀）；未整理 → muted `未整理的题不能加入复习`，无按钮）、错因状态（每错因加粗 + pill + 已解决未到期时 `· 下次复查 {date}` + `解决次数 N` + 补救行 `上次是这么补的：…`；无错因 → `还没填错误类型，先在上面的编辑里补上`）、解决次数（`共解决错因 N 次 · 自查「已解决」N 次 · 「未解决 / 不确定」M 次（同一错因在同一道题上两次「已解决」算已解决）`，由 `_history` 计数）、解决记录（全部）（全部历史行 `日期 · 已解决/未解决/不确定`，13px muted；空 → `暂无复习记录，去复习页练一次会出现在这里`）。加入口径沿用基线 `canJoin = q.isOrganized || q.isArchived`（未整理题无按钮）；q-math-2 边界见 §6。
- **底部操作区**（Wrap，顶边框，margin-top 22 / padding-top 18）：`返回{来源}` / `☆ 收藏` 或 `★ 已收藏（点击取消）` / `归档` 或 `恢复（取消归档）` / `← 上一题` / `下一题 →` /（编辑态：`保存` primary + `取消`）/ `删除`（其余均为 QmButton plain）。全页无“开始复习”按钮。基线底部的“复习次数 N 次”行已删（信息在复习记录·解决次数里）。
- **删除**：内联 `_buildConfirmBox`（err-bg/err-line/err-ink，圆角 12，padding 12×14），粗体 `删了就没了，确定吗？` + `「{学科} · {题型}｜{题名}」整题图与全部补充内容一并删除，不可恢复。` + `确认删除`（primary 小）/ `取消`。`_doDelete` 删除后进列表下一题并复位答案/展开/编辑态；删最后一题时 pop（该路径未做 widget 测试，见 §6）。
- **取消编辑**：不用对话框。`_requestCancelEdit`（干净 → 直接退出编辑；有改动 → 显示内联确认框并确保信息段展开）；`_onPop`（未编辑 → 离开；编辑中干净 → 先退出编辑再离开；编辑中有改动 → 显示内联框并停留）。框内三按钮：`保存并退出` / `不保存，丢弃改动` / `继续编辑`。
- **Token 来源**：全部颜色取自 `DesignTokens`（深色纸面 `#D8DCE2`、深色主色 `#7FA8D0`，D1/D2 已确认；详情度量见 §1）；组件全部用 UI Kit；文字符号（`★` `☆` `▸` `▾` `←` `→`）不用图标字体；缩放唯一映射 1.00/1.15/1.30，字号只在 app.dart TextScaler 处乘一次，布局尺寸按 `qmScaleOf` 乘一次，不用 Transform.scale。

## 4. 测试与构建结果

- `flutter analyze`：**No issues found!**
- `flutter test` 全量：**185/185 通过**（R1–R6 的 161 个 + R7 新增 24 个）。
- `flutter build linux --release`：**成功**，产物 `build/linux/x64/release/bundle/quiz_master2`（本次构建未清 `build/linux` 即成功；R0 已知的 CMakeCache 问题未复现）。
- Flutter/Dart 3.47.9 / 3.13.7，路径 `~/workspace/flutter-install/flutter/bin/flutter`。
- R7 新增 24 个测试覆盖：默认全折叠 + 工具栏 + 无“开始复习” + 无 Icon；`sourceLabel` 复习；副标题错因 pill；答案显示/收起 + 空态待补充 → 编辑；编辑态答案提示；信息查看态 7 字段 + 来源；复习已加入/取消加入/加入/未整理/无错因提示 `先补错误类型`；编辑保存（题名）、取消干净、取消有改动内联三按钮流程；编辑表单 chips/下拉；收藏切换；归档切换 + 横幅；删除取消/确认 → 下一题；上一题/下一题顺序 + 两端禁用；空文本横幅；`imageFailed` 占位（`数` + `数学 · 极限题` + error 横幅）；亮/深 × 1.00/1.15/1.30 无溢出（查看态 + 编辑态）。
- 测试编写教训（写给后续轮次）：屏幕外点按在 720 视口会落空——先 `ensureVisible`；同一 testWidgets 内重复 `pumpWidget` 会复用旧 State——每次 pump 用 `UniqueKey()`（R6 同款）；`find.text` 匹配 `Text.rich` 是整串纯文本，拼接文本用 `textContaining`；删 q1 后 `['q1','q2','q3']` 变 2 题，工具栏读 `第 1 / 2 题` 不是 `第 2 / 2 题`；副标题错因 pill 在复习段折叠时也可见，计数会把它算进去。

## 5. 截图对照（Xvfb 1280×720，真实库 9 题、数学已整理 2 道）

截图目录 `docs/ui-replication/shots/r7/`（35 张 PNG：14 张 Flutter + 7 张回归 + 6 张 HTML + 6 张对照图 + 2 张探针）。HTML 原型是静态演示数据（数学 3 道题全已整理、DEMO_TODAY 2026-11-11），与真实库数字/题型/错因/答案不同——对照只看结构/样式/文案，不逐数比对。HTML 首题与 Flutter 首题恰好是同一道题干（定积分阴影面积），题名/题型/错因/答案仍不同：HTML `数学 · 图片题｜定积分的几何意义（带图题）` / 审题失误 / 答案 `4/3`；Flutter `数学 · 图表题｜定积分阴影面积` / 计算错误 / 答案 `见解析`；HTML `第 1 / 3 题`，Flutter `第 1 / 2 题`（真实库错题本列表只收已整理题）。

| 截图 | 对照结论 |
|---|---|
| `detail-light/dark-standard.png` | ✓ 工具栏 `← 返回错题本` + `第 1 / 2 题 · 按错题本当前的顺序` + `编辑`；标题 + ☆；副标题 + `[解决中]` pill（换两行，见下）；纸面 `#FFFDF4`（亮）/ `#D8DCE2`（深，D1）+ 提示行；三段全折叠 `▸`。与 HTML 结构一致；差异：HTML 详情在壳内带左导航，Flutter 是推送全窗路由、无左导航（基线架构）；HTML 副标题错因状态是纯文本，Flutter 是 pill；HTML 纸面有完整手绘图（y=1 / y=x² / 图 1），Flutter 是占位切片的简化 CustomPaint（R5 §6.2 同款已知近似）。 |
| `detail-light/dark-large.png`、`detail-light/dark-extraLarge.png` | ✓ 三档无溢出；特大档副标题换两行（`错因：计算错误 · [解决中]` 落第二行），纸面与折叠正常。 |
| `detail-answer-light-standard.png` | ✓ 答案解析展开：答案 `见解析` / 解析 `阴影面积 = ∫(1 − x²)dx（定积分表示）。` + `收起答案`。与 HTML 同结构（HTML 答案 `4/3`，数字差是演示数据不同）。 |
| `detail-info-dark-standard.png` | ✓ 题目信息展开：两列网格，首行 `学科（不能改） 数学` / `文件夹（归类） 模拟卷`；段内其余字段在视口下方（整页可滚）。 |
| `detail-review-light-standard.png` | ✓ 复习记录展开（箭头 `▾`，首行 `复习` / `错因状态` 入镜）；段内完整内容由 widget 测试覆盖，HTML 对照见 `compare-detail-review-light.png`。 |
| `detail-edit-light-standard.png` | ✓ 编辑态：右上 `保存` / `取消`、题名 TextField、三段全展开、答案解析段显示“正在编辑”提示。 |
| `detail-delete-dark-standard.png` | ✓ 删除确认框完整入镜：`删了就没了，确定吗？「数学 · 图表题｜定积分阴影面积」整题图与全部补充内容一并删除，不可恢复。` + `确认删除` / `取消`。 |
| `detail-zoom-light-standard.png` | ✓ 放大浮层：`整题图 · 放大查看` + `150%` + `+` / `−` / `关闭 ×` + 提示 `回到题目详情`。但纸面左移、左侧文字被裁（见下“放大浮层初始偏移”）。 |
| `detail-empty-light-standard.png` | ✓ 空态：黄色 warn 横幅 `这道题还没有补充任何文字内容：答案、解析均显示「待补充」，点「待补充」或右上角「编辑」就能补。`；真实库无全空题，本张靠临时把 q-math-3 的答案/解析/备注置 NULL 拍，拍完已恢复。 |
| `detail-favorite-dark-standard.png` | ✓ 收藏态：第二题 `数学 · 极限题｜函数极限`，金色 ★，`第 2 / 2 题`，错因 `概念不清 · [待解决]`。 |
| `regress/nav-home.png`、`nav-wrongbook-shelf.png`、`nav-wrongbook-directory.png`、`nav-wrongbook-list.png`、`nav-detail.png`、`nav-back-list.png`、`nav-back-home.png` | ✓ 首页 → 书架 → 目录 → 列表 → 详情 → 返回列表 → 回首页链路正常；返回列表后仍在数学列表（2 道题），回首页后“继续上次”正常。 |
| `html-detail-light/dark.png`、`html-detail-answer-light.png`、`html-detail-info-dark.png`、`html-detail-review-light.png`、`html-detail-edit-light.png` | ✓ Playwright 截的 HTML 原型详情页（只截 `.win` 应用框，无介绍头、无复查提醒 toast）；首题与 Flutter 同题干。HTML 信息展开含“错误原因（错因）”自由文本与“收集文件：导入文件：高数模拟卷.png”两行，Flutter 无对应模型字段（见 §6）；HTML 编辑表单无题名栏，Flutter 保留基线题名编辑（见 §6）。 |
| `compare-detail-light/dark.png`、`compare-detail-answer-light.png`、`compare-detail-info-dark.png`、`compare-detail-review-light.png`、`compare-detail-edit-light.png` | ✓ HTML（上）/ Flutter（下）并排对照 6 张。结构/样式/文案一致；剩余差异见本表各行与 §6（左导航、副标题 pill、纸面手绘图 vs 占位切片、HTML 设计说明文案不抄、数字/题名/错因/答案是演示数据 vs 真实库）。 |

### 本轮截图发现并已修的两个真问题

1. **编辑/删除点击坐标目测估偏，初版两张状态图全是默认态**：初版编辑点 (963,45) 落在编辑按钮右缘外 5px（按钮实测 x 877–930，中心 903）；删除点 (1100,690) 落在空白处，后改 (700,665) 又打中 `下一题 →`（删除按钮文本中心实测 x≈785，目测偏了 85px），截图成了第二题详情页。修复：两处改像素实测中心——编辑 (903,45)、删除 (785,665，滚 3 下后）；删除点按后再滚 2 下，确认框才完整入镜。重拍后两张正确。教训：**缩放后截图里的目测坐标不可靠，必须用像素扫描定位**（见下）。
2. **QuestionSlice 深色纸面是纯白，与 D1 冲突**：探针图发现深色下大题图是纯白底（写死 `#FFFFFF`）。修复：纸面改 `palette.paper`（深 `#D8DCE2`）+ `paperLine` 边。副作用：错题本大卡片与整理台切片深色下同步由白变 `#D8DCE2`，更接近 HTML/D1，但 R5/R6 的深色截图因此过期（见 §6）。

### 截图脚本的坐标校准（教训，写给后续轮次）

- **像素扫描定位法**（本轮定下）：不要凭缩放后的截图目测。按钮文本中心用 PIL 扫：深色像素聚类找文本行中心（删除按钮文本 `774–796` → 中心 785）；主色按钮扫蓝色块边界（编辑按钮蓝块 x 877–930 → 中心 903）。实测中心（标准档 1280×720）：编辑 (903,45)、返回错题本 (190,45)、删除（滚 3 下后）(785,665)、折叠头 (400,568/627/685)、看答案 (200,610)、纸面中心 (640,345)、首卡 (640,300)、第二卡 (640,495)。
- 删除确认框在操作区下方，点删除后须再滚 2 下才完整入镜（脚本已加 `scroll_down_n 2`）。
- HTML 截图脚本：`data-nb-open` 是原型里的死绑定（模板从不设置该属性），`[aria-label^="查看题目详情"]` 也不匹配（label 以“第 1 张，”开头）；列表行是 `div.nb-card[data-nb-row="m3"]`（role=button）。修复：用 `[data-nb-row="m3"]` 点首题；回列表后重进同法。另：HTML 详情返回用 `[data-detail-back="1"]`。
- 对照图标签：R6 的 PIL 默认字体画不出中文（标签是 tofu 方块）；本轮 `make-compare-r7.py` 改 Noto Sans CJK（`/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc`），标签可读。
- 放大浮层初始偏移（**未修**，见 §6 第 3 条）：R7 截图与 R5 `organize-zoom-light-standard.png` 同款——1.5× 下纸面左移、左侧文字被裁；`_centerInitial` 的居中换算未彻底修好。这是共享 `showQuestionZoomDialog` 的旧问题，R7 未动（动它会同时影响整理台，且根因在 InteractiveViewer 子节点尺寸与变换原点的换算，需另立项修）。

## 6. 未解决问题

1. **Win11 字体/DPI/窗口尺寸待真机复核，Linux 结果不替代 Win11 验收。** 尤其 Linux 回退字体（Noto Serif CJK）与 Win11 的微软雅黑/等线行高度量不同，各处 11–13px 小字与标签需真机确认无裁切；1280×720 以外窗口尺寸（HTML 断点按窗口宽）也须真机复核；Windows Release 构建须在 Meng 的 Win11 机器上验证。
2. **`imageFailed` 图片失败占位在应用内无触发入口**（无真实图片通道），只在 widget 测试级验证；与 R6 `QuestionSlice(failed: true)`、R5 `imageFailed` 开关同款情况。
3. **放大浮层 1.5× 初始偏移**（R0 已知，R5 的 `_centerInitial` 未彻底修好）：详情与整理台共用 `showQuestionZoomDialog`，打开时纸面左移、左侧文字被裁；拖动/滚轮缩放仍可用，`+`/`−`/关闭/Esc 正常。需另立项修，不在 R7 范围内。
4. **R0 §6-B 业务问题**（报告范围口径、新增学科不同步、启动页未生效、通知/备份不完整）未动。
5. **分页 / 真实 YOLO / 真实图片切片 / 系统拖放仍未验证**（R7 范围外既有项）。
6. **HTML 与模型之间的既有缺口（未动，不发明字段）**：HTML 自由文本“错误原因（错因）”与“收集文件”来源行无 Flutter 模型字段；标题编辑是基线功能保留（HTML 编辑表单无题名栏）；q-math-2 边界（有文件夹但 `isOrganized=false`，按任务口径无“加入复习”按钮，HTML 按文件夹有无判断则会显示）；副标题错因状态 HTML 是纯文本、Flutter 是 pill 且标准档换两行。
7. **`CompactSliceThumb` 仍白色**（与 §5 第 2 条的 QuestionSlice 纸面改动不一致），后续轮次可顺手统一。
8. **QuestionSlice 纸面改动的副作用**：R5/R6 的深色截图（整理台切片、错题本大卡片）现渲染 `#D8DCE2` 纸面而非白色，更接近 HTML/D1，但旧截图已过期；重拍在后续轮次。
9. **详情页是推送路由、无左导航**（基线架构；HTML 详情在壳内带左导航）；删除最后一题 → pop 路径未做 widget 测试（只覆盖删后进下一题）。
10. **空态截图用临时数据**：真实库无全空题，空态图靠临时 NULL 化 q-math-3 答案/解析/备注拍摄，拍完已随备份恢复。
11. **左导航学科速览数字换行**（R6 §6.6 同款既有行为，非 R7 引入）。

## 7. 验收后状态

- 真实库已恢复原状：9 道题、数学已整理 2 道、已归档 0 道，`themeMode=dark`、`fontSize=standard`；截图备份 `.qm2-r7-backup.db` 已删除；临时 NULL 化的 q-math-3 字段已随备份恢复。
- 未 commit、未 push。
