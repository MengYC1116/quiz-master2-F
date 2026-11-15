# B8-7 题目详情页重新设计

## 定稿

**Meng 2026-11-15 15:44 定稿：A 紧凑信息卡**（`docs/ui-replication/shots/b8-detail/01-variant-a-compact.png`）。
B 学科色带、C 宽屏双栏废弃：代码分支已随定稿删除，仅截图留档（`02-variant-b-colorband.png`、`03-variant-c-twocolumn.png`）。

## 改了什么

只改两个文件（未提交、未推送）：

- `lib/modules/detail/question_detail_page.dart`
- `test/detail_page_test.dart`

### A 紧凑信息卡（最终实现）

- 内容宽 1160（原 token 1004），整题图限高 460（原 320）；工具栏→标题 14→10、标题→副标题 8→6、三段间距 14→12。
- 标题前加学科图标章：34px 圆角方块，学科色底 + 白字单字图标（如「数」）。
- 副标题拆两行：第 1 行「学科：数学 · 错因：概念不清 · 待解决」pill，第 2 行只读说明小字（muted）。
- 新增信息条（只读，编辑态隐藏）：文件夹 chip（学科 tint）+ `#标签` chip + 加入复习状态 pill（「已加入复习」/「未加入复习」）。
- 三段头各加一行摘要（折叠态可见）：答案解析「已填答案与解析 / 答案与解析待填写」；题目信息「文件夹 n · 知识点 m · 标签 k / 信息待补充」；复习记录「已加入复习 · 待解决 n 个错因 / 未加入复习 / 未整理，不能加入复习」。
- 底部操作（返回 / 收藏 / 归档 / 上一题 / 下一题 / 删除）收进一张满宽卡片（surface2 底，radius 12，padding 14），不再是白底上一条分隔线 + 漂浮按钮。
- `withOpacity` 换成 `.withValues(alpha: …)`（6 处），清 deprecation 提示。

### 不改行为（已定结构与功能原样）

分段折叠式（三段默认折叠）、大图在上（点击放大 + 滚轮缩放）、年轻伙伴风格；编辑模式（保存生效、取消脏检查）、学科不可改、「看答案」后显答案/解析（空显可点「待补充」）、复习记录区「加入复习 / 取消加入复习」、收藏/归档/删除/上一题/下一题（删除确认「删了就没了，确定吗」后自动进下一题）、无「开始复习」按钮、按来源列表顺序上下题。重框入口行为未动（另一组在删二层模型）。

## P1-2 题图区按内容高度自适应（Meng 裁决，2026-11-15）

审计 P1-2：题图区限高 460 后，演示题小图只占盒子约 15%，首屏近半米色空白。Meng 裁决：**改成按内容高度自适应，上限 460 不变，不再固定撑满 460**。P1-1（底部操作卡在首屏外）同时裁决：**接受现状，不改**，不做吸顶/吸底条。

### 根因

演示题无真实切片，走 `QuestionSlice` 的 sliceText 占位（`Center > Padding > Column(mainAxisSize: min)`）。`Center` 在有界高度约束（`BoxConstraints(maxHeight: 460)`）下会撑满整个 460 盒子，内容（文字 1 行 + 48 高简图 + 上下 padding，约 96px）居中，只占约 15%。真实图片不受此影响（`Image` 按固有尺寸走）。

### 改法（只改详情页题图区，`lib/modules/detail/question_detail_page.dart`）

- `_buildImageBlock` 里把 `QuestionSlice` 包一层 `IntrinsicHeight`：盒子高度取内容固有高度；`QuestionSlice` 自身的 `BoxConstraints(maxHeight: 460)` 不变，大图仍限高 460。
- `imageMaxHeight = 460.0` 常量与 `maxHeight: imageMaxHeight` 传参不动；`fixedHeight` 不动（详情页本就按内容走）。
- 未动 `widgets.dart`（共享 `QuestionSlice`，错题本大卡片 `fixedHeight: true`、整理页、放大浮层都不受影响）；未动 P1-1、P1-3、P2 项。

### 验证

- `flutter analyze`：**0 问题**。
- `test/detail_page_test.dart`：**37/37 通过**（新增 2 个 P1-2 用例；setUpAll 新增 200×800 真实切片 `slices/tall.png`，同步文件 IO，测试体无异步文件 IO）。
  - 小图（占位）：渲染高 < 200 且 > 50（实测约 96），不再撑满 460。
  - 大图（200×800 真实切片）：渲染高 = 460，限高仍在。
  - 大图用例的坑：`QuestionSlice` 用 `Image.file + cacheWidth`（`ResizeImage`），目标尺寸解码是原生异步，fake async 下只等真实时间不够——须像 SR2-3 那样在 `runAsync` 里边 `pump` 边等（20×200ms），图载入后 `IntrinsicHeight` 才量到固有高；直接 `Future.delayed` 2 秒仍为 2×2。
- Linux Release 构建：**通过**（`✓ Built build/linux/x64/release/bundle/quiz_master2`）。
- 截图：A 图已重截替换 `docs/ui-replication/shots/b8-detail/01-variant-a-compact.png`（改前 A 图无留档，改前对照见 `00-before.png` 的 460 高盒子；B/C 截图留档不动）。同一题目、同一窗口 1440×900、同一导航路径（错题本 → 数学封面 → 全部题目 → 第 2 张卡 q-math-1）。新图核对：题图盒子约 100 高，三段 + 底部操作卡片全部进首屏。截图脚本 `/tmp/b8-p12-shot-detail.sh`（B8-7 的 `/tmp/b8-shot-detail.sh` 已随 /tmp 丢失，按 B8-8 的隔离做法重写：隔离 HOME + v2 演示库副本、Xvfb `:99`、`xdotool getwindowpid` 核对窗口归属、按确切 PID 杀进程；导航坐标：错题本 (100,225)、数学封面 (400,350)、全部题目 (600,195)、第 2 张卡 (700,400)）。
- 演示库：启动用 v2 派生库副本（`~/workspace/demo-db-backup/quiz-master2-v2-demo.db`，v1 库启动时按 §6 会被删库重建为空，B8-7 实测截图用的也是 v2 派生库）；live 库与 v1 备份全程只读，跑前跑后 md5 均为 `8f7f9c64405dc6e484ac2bf8e5e1a807`，未动。
- 过程记录：`TMPDIR=$HOME/workspace/.tmp-flutter` 会让 SR2-3 的 `.tmp-` 残留断言误报（临时目录名本身含 `.tmp-`），测试须用默认 /tmp 跑；`flutter analyze` 曾报另人工人未提交文件 `box_editor.dart` 的 2 条 info lint，与本次改动无关，复核时已消失（对方已修）。

## 三个方向对比

| 方向 | 做法 | 截图 |
|---|---|---|
| A 紧凑信息卡（**定稿**） | 单栏，收紧间距 + 图标章 + 信息条 + 段摘要 + 底部操作卡片 | `docs/ui-replication/shots/b8-detail/01-variant-a-compact.png` |
| B 学科色带（废弃） | A + 标题区改为学科软色通栏（48px 章 + 标题 + 错因行 + 信息条都在带里），图限高 520，操作卡片用学科 tint | `docs/ui-replication/shots/b8-detail/02-variant-b-colorband.png` |
| C 宽屏双栏（废弃） | 内容宽 1280，>960 时左栏图 + 答案解析、右栏题目信息 + 复习记录；≤960 自动回单栏 | `docs/ui-replication/shots/b8-detail/03-variant-c-twocolumn.png` |

改前对照：`docs/ui-replication/shots/b8-detail/00-before.png`（Batch 7 代码，同一题目、同一窗口尺寸 1440×900）。

C 的取舍（随废弃失效，仅留档）：C 把「大图在上」改写为「图在左栏上」，与已定「大图在上」有出入；若将来重提双栏，需先确认这条是否接受。

## 截图方法与一次乌龙

- Xvfb `:99`（1440×900）、Release 构建真跑、同一导航路径：错题本 → 数学封面 → 全部题目 → 第 2 张卡（q-math-1「数学 · 极限题｜函数极限」）。截图脚本 `/tmp/b8-shot-detail.sh <输出路径>`（核对演示库 → 启动 → 找主窗口 → 调 1440×900 → 导航 → 截屏，打印应用 PID）。
- **乌龙**：第一批 A 截图里三段卡片「约 0 高、标题不可见」，widget 测试却布局正常。根因是**两个应用窗口叠在一起**：旧二进制进程（PID 16872，1440×900 窗口）在下、新二进制进程（PID 23476，1280×720 窗口）在上，根窗口截图拼出「上半新代码 + 下半旧代码」的假象。教训：`$!` 拿到的是启动链的 shell 进程号，不是应用进程号；此后一律用 `xdotool getwindowpid` 核对窗口归属、按确切 PID 杀旧进程、只留一个应用实例后再截屏。最终三张截图均在单实例下重截，像素已核对（星标 x≈1200 属 1280 宽窗口内容区、与窗口几何一致）。
- 三方向截图均为 Release 真机渲染，非 widget 测试拼图。

## 验证

- `flutter analyze`（全仓）：**0 问题**。
- `test/detail_page_test.dart`：**37/37 通过**（原 35/35，P1-2 新增 2 个用例，见上节）。B8-7 新增用例 5 个（信息条、三段摘要、图限高 460、编辑态隐藏信息条、亮/深 × 1.30 无溢出）；另 1 个既有用例因标题章同字「数」出现两次，期望由 `findsOneWidget` 改为 `findsNWidgets(2)`（有注释）。
- 全量测试串行（`--concurrency=1`，onnxruntime `LD_LIBRARY_PATH`）：**849/849 通过**（exit=0，日志 `/tmp/b8-7-full-test.log`，`[E]` 0 处）。总数与 Batch 7 基线 879 不同：Batch 8 各组同期增删了用例（日志可见 B8-1 新增用例、二层清理删用例等）；本页文件 35/35 已单独核对。
- Linux Release 构建：**通过**（定稿 A 代码重建，`✓ Built build/linux/x64/release/bundle/quiz_master2`）。
- 截图核对：三方向 + 改前均在 1440×900 同一题目下截取；A 图中标题章、信息条、三段摘要、满宽操作卡片均可见。**P1-2 后 A 图已重截**（题图盒子约 100 高，三段 + 底部操作卡片全部进首屏），见上节。

## 演示库

- 标准演示库是 **v1**：`~/workspace/demo-db-backup/quiz-master2.db`，md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`，`user_version = 1`，9 道题、3 学科。跑完已恢复并核对 md5。
- 截图用的 **v2 派生库**：`~/workspace/demo-db-backup/quiz-master2-v2-demo.db`（v1 的 5 个多值字段由逗号连接改写为 JSON 数组，`user_version = 2`，9 道题、7 条错因记录）。背景：应用按 §6 决定打开 v1 库会直接删库重建（不迁移），且 v2 编解码只读 JSON 数组，逗号值会解码为空；该派生库**不是**标准演示库备份，不要拿它当备份恢复。
- 共享树/共享 live 库被多个 Batch 8 工人同时改写：截图期间 live 库两次被覆盖回逗号编码（信息条/错因 pill 消失），均从 v2 派生库恢复后重截；另一次全量测试在运行 18 分钟后被运行时重启打断、无输出落盘，已用日志文件方式重跑。

## 技能使用

按 Meng 要求先用 `muse.skill_search` 找设计/UI 技能：**目录里没有专用的 UI/视觉设计技能**。最接近的是 `app-creation`（`/opt/muse/skills/app-creation/SKILL.md`，已通读并遵循：先读现有组件/token/资产、沿用项目 `DesignTokens` 与已定年轻伙伴风格、不凭空手写、按用户真实路径验证主流程与空/加载/错误态、构建成功不等于可用——以运行中的应用截图为准）。报告按 `documents` 技能规范写（Markdown、开门见山、主张附证据）。

## 遗留

- `DesignTokens.detailContentMaxWidth`（1004）与 `detailSectionGap`（14）已被本页弃用，留在 `design_tokens.dart` 未动（共享文件，另一工人在改；定稿后可顺手清理）。
- 全量测试第一次跑时 4 个重框用例曾短暂失败，单跑即过、重跑全文件 37/37——判定为多 worker 并发跑测试的干扰（hooks_runner 锁 / CPU 争用），非本页改动所致；定稿后最终全量以日志为准。
- 截图脚本与中间图在 `/tmp`（`b8-shot-detail.sh`、`b8-a-fixed.png` 等），截图产物本身在 `docs/ui-replication/shots/b8-detail/`，不推送。
- 第 2 项工人同期从本文件清除了二层模型残留（`inners`/`standalone` 等），与本次改动无冲突；`git diff 622b6b6` 中本文件的 414 增 / 248 删含该清理与本次改动两部分。
