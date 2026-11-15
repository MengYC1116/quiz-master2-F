# B2 错题本书架封面样式 — 修复报告（工人 C）

- 日期：2026-11-14
- 分支：`ui-replication`（未 commit、未 push；不推代码）
- 范围：只改书架封面（三个学科封面）——`lib/modules/wrongbook/wrongbook_page.dart` 的 `_buildBook` 及封面绘制代码 + `test/wrongbook_page_test.dart` 新增 1 项回归测试；已归档入口未动；学科管理页 52×68 封面小预览未动（见 §6）。
- 对照：实拍 `workspace/user/media_library/image/image-83.png`（Win11 旧版）、预览 `image-84.png`；取值以完整预览 HTML 为准，原型版已核对（见 §4）。

## 1. 第 1 处（顶部英文）——按 Meng 决定取消，不恢复

- 任务书原第 1 处（恢复英文映射）在开工后被纠正取消。Meng 2026-11-14 明确：**封面顶部不显示任何英文，数学/英语/政治/新学科一律不显示**，保持之前删英文的决定；预览 HTML 里还留着 MATHEMATICS，那是预览和 App 有意的不同点，不用管。
- 执行：未恢复英文映射，未加英文元素；并 grep 确认 `lib/modules/wrongbook/wrongbook_page.dart` 里已无 `MATHEMATICS` / `ENGLISH` / `POLITICS` / `enName` 残留（0 处）。`test/wrongbook_page_test.dart` 里的三词只出现在注释与“无英文行”断言中（`findsNothing`），是回归保护而非显示。
- 因此第 6 处（学科名位置）按纠正后的口径处理：没有英文行，但学科名**不顶上去**，仍按预览排布（见 §3 第 6 处）。

## 2. 改动总览（只改 `_buildBook` 及其画笔）

| 位置 | 改动 |
| --- | --- |
| `_WrongbookPageState._hoverBookId`（新增） | 书架悬停的书 id；悬停时封面按 HTML 上移 4px、阴影加深（见 §3 悬停） |
| `_buildBook` 外层 | `InkWell > Container` 改为 `MouseRegion > InkWell > AnimatedContainer`（150ms，与 HTML `transition .15s` 一致），阴影随悬停在 `0 10px 22px / .20` 与 `0 16px 30px / .24` 间切换 |
| Stack 图层 | 顺序改为纹样 → 内阴影 → 虚线内框 → 书脊 → 书页边 → 折角 → 内容列（与 HTML 绘制顺序一致）；新增内阴影画笔与书页边画笔 |
| `_CoverFoldPainter` | 重写：渐变 + 正确三角 + 左下圆角 8px + 方块阴影（见 §3 第 3 处） |
| `_DashedBorderPainter` | `radius: double` 改为 `borderRadius: BorderRadius`，支持 HTML 的不对称圆角 4 9 9 4 |
| `_CoverInsetShadowPainter`（新增） | 两层 inset 阴影 |
| `_CoverPageEdgePainter`（新增） | 右侧书页边 |
| `_CoverPatternPainter` 的 `plain` 分支 | 删 28px 白色三角（见 §3 第 3 处末） |
| 学科名上方 | 加 `SizedBox(height: 40.4 * scale)` 占位（见 §3 第 6 处） |
| 「错 题 本」 | `padding-left` 13.6 → 0（见 §3 第 6 处末），颜色加 opacity .95 |
| 计数条标签 | 颜色加 opacity .92（HTML `.nbc small`） |

未动：7 个预设色（`CoverTokens` 蓝 `#2F7CF6` 等）、6 种样式只叠纹样的规则、封面底色、计数条底色/边框/圆角/字号、`_CoverReviewButton`（已与 `.nb-cover-rev` 一致）、已归档入口、数据库 Schema、依赖、`pubspec.lock`。

## 3. 逐项：改前 → 改后（值全部取自预览 HTML）

### 第 2 处 蓝色：改前已是预览色，无需改值；“深浅变化”由内阴影实现

- 预览：数学 `#2F7CF6`、英语 `#1F9D66`、政治 `#E0524D`、其他 `#64748F`，纯色（见 §4）。
- 改前：`CoverTokens` 蓝已是 `0xFF2F7CF6`，绿/红/灰亦与预览一致。实拍像素验证：改前截图数学封面取样 `srgb(47,124,246)` = `#2F7CF6`；绿 `(31,157,102)`、红 `(224,82,77)` 均与预览一致。image-83 里看着偏亮的蓝是旧版构建的色值，当前代码早已是预览色。
- “上下带一点深浅变化、底部略深”：两版 HTML 的封面底色都是纯色，没有纵向渐变（见 §4）；变化感来自 `box-shadow` 的两层 inset（左暗右亮）+ 计数条的深色半透明叠加。本次把两层 inset 阴影补上了（新增 `_CoverInsetShadowPainter`：左 `inset 4px 0 8px rgba(0,0,0,.18)` → 12px 内渐隐暗带；右 `inset -2px 0 4px rgba(255,255,255,.14)` → 6px 内渐隐亮带）。注意左 inset 大部分被 11px 书脊盖住，只在脊边透出一点，与 HTML 的绘制顺序一致。

### 第 3 处 折角：改前大白三角 → 改后 34px 渐变三角 + 圆角 + 阴影

- 预览 `.nb-book-fold`：34×34；`linear-gradient(225deg, transparent 49%, rgba(0,0,0,.16) 50%, #FFFDF4 52%, #E9E2CC 100%)`；`border-radius 0 0 0 8px`；`box-shadow -2px 2px 4px rgba(0,0,0,.18)`。
- 改前：纯色 `#FFFDF4` 大三角 + 1.5px 斜边暗线，无渐变、无圆角、无阴影。
- 改后（`_CoverFoldPainter` 重写）：同一渐变（`LinearGradient`，`topRight → bottomLeft`，stops `0.49 / 0.50 / 0.52 / 1.0`）；左下角圆角 8px（二次贝塞尔，切线与两边相切）；阴影用 `canvas.drawShadow`（方块路径，elevation 4，色 `rgba(0,0,0,.18)`）——按 CSS `box-shadow` 的做法只落在方块之外，方块内不染暗；HTML 的 -2 横向偏移在该模糊下不可见，取 0，已在代码注释中写明。
- **中途纠正过一次画错（已修正，见过程记录）**：第一版把纸色三角画成了顶点为左上/右上/左下的三角（`moveTo(0,0) → (w,0) → (0,h)`），渐变的纸色部分只落在斜边附近一小条，截图看着像个小三角旗。与预览逐像素核对后确认：CSS 渐变 t>0.52 的纸色区是 34×34 方块内对角线 y=x 左下方的三角，顶点是左上、左下、右下（斜边即对角线，暗线正好落在斜边上，圆角在左下）。已改成该三角，并用折角特写三图（预览 / 改前 / 改后，`fold-compare.png`）核对通过。
- 顺带去掉 `_CoverPatternPainter` 的 `plain` 分支里 28px 白色三角（`white .28`）：它是旧折角的叠加残留，HTML 的 plain 样式没有它；它与新折角重叠后会在角落留一块洗白的半透明区。去掉后角落是干净底色，与预览一致。`double`（双线框）样式的折角仍显示（HTML `cv-frame` 会藏折角，见 §7 遗留）。

### 第 4 处 虚线内框：改前已基本一致，只补圆角不对称

- 预览 `::before`：`inset 9px 9px 9px 15px`、`1.6px dashed rgba(255,255,255,.55)`、`border-radius 4px 9px 9px 4px`。
- 改前：inset、线宽、透明度已与预览一致；圆角是统一的 9px。
- 改后：圆角改为左上 4、右上 9、右下 9、左下 4（`_DashedBorderPainter` 改为接受 `BorderRadius`）；虚线节律保持 7px 实线 / 4px 间隔。

### 第 5 处 数字条：改前已是预览值，只补标签透明度

- 预览 `.nb-book-counts`：`rgba(0,0,0,.20)` + `1px rgba(255,255,255,.35)` 边框、圆角 12、`padding 10px 4px`；数字 21px/800；标签 12px opacity .92。
- 改前：底色/边框/圆角/字号已与预览一致（实拍取样计数条区 `srgb(38,99,197)` = `#2F7CF6 × 0.8`，正是黑 .20 叠加的结果；image-83 里偏浅的条是旧版）。
- 改后：只把标签颜色从纯白改为 `rgba(255,255,255,.92)`；数字保持纯白；「错 题 本」颜色改为 `rgba(255,255,255,.95)`（HTML `.nb-book-sub` opacity .95）。

### 第 6 处 “数学”位置：改前顶到内边距 → 改后与预览同高（74.4px）

- 预览纵向排布：内边距顶 34px + 英文 `margin-top 26px` + 英文行高 `12px × 1.2 = 14.4px` → 学科名顶在距封面顶 **74.4px** 处。
- 改前：无英文行，学科名顶在 34px 处（顶上去了）。
- 改后：学科名上方加 `SizedBox(height: 40.4 * scale)` 占位（26 + 14.4 = 40.4），学科名仍在 74.4px 处。像素实测（`after-dark.png` 数学书）：书顶 y=158，学科名字墨顶 y≈232，即顶 +74px，与 74.4 一致（字墨顶比文本框顶低约 0.4px 的取整/抗锯齿误差）。
- 副标题 `padding-left` 的取舍（实测纠正）：HTML 写 `padding-left: .85em`（13.6px）是为了抵消 CSS 字距在末字后多出的一格；但 Flutter 的 `Text` 不把末字后的字距算进宽度，照搬 13.6 反而右偏。实测：改前 padding 6.8 时「错 题 本」字墨中心比书中心右偏约 +5px，学科名（无 padding）居中无偏；故 Flutter 侧 padding-left 取 **0**，与预览“居中”的视觉结果一致（改后字墨中心偏移 +4.5px，预览同法测量为 -2px，差值在字墨抗锯齿误差内；学科名与副标题的相对位置与预览一致：预览副标题比学科名右偏 +3px，改后 +4.5px）。

### 第 7 处 书的感觉：补书页边 + 书脊 + 阴影

- 预览：`::after` 书页边（右缘 5px 处、4px 宽、`repeating-linear-gradient(180deg, #F5EFDD 0 3px, #D9D2BC 3px 4px)`、opacity .85）+ `.nb-book-spine`（左 11px、`rgba(0,0,0,.20)`、右缘 `1px rgba(255,255,255,.25)`）+ 外阴影 `0 10px 22px rgba(23,35,59,.20)` + 两层 inset 阴影（见第 2 处）。
- 改前：书脊、外阴影已有；书页边、inset 阴影缺失。
- 改后：新增 `_CoverPageEdgePainter`（3px `#F5EFDD` + 1px `#D9D2BC` 循环，每条按 .85 画，与整层 .85 叠加等价），`Positioned(right: 5, width: 4)`，画在书脊之后、折角之前（折角 z-index 2 盖住书页边顶部，与 HTML 一致）；新增 `_CoverInsetShadowPainter`（见第 2 处）。图层顺序：纹样 → 内阴影 → 虚线内框 → 书脊 → 书页边 → 折角 → 内容列。
- 悬停（预览 `.nb-book:hover`，任务书给出的值里包含）：新增 `MouseRegion` + `AnimatedContainer`（150ms），悬停时整本上移 4px、阴影变为 `0 16px 30px rgba(23,35,59,.24)`。实测：悬停截图数学书顶 y=154，非悬停 158，正好上移 4px。

## 4. 渐变核对：两版 HTML 的封面底色都是纯色，无纵向渐变

- 完整预览与原型版（`quiz-master2-jiao-hu-yuan-xing.html`）的 `.nb-book` CSS 逐行一致：`background: #2F7CF6`（数学）/ `#1F9D66` / `#E0524D` / `#64748F`，无 `linear-gradient` 做底色；唯一的渐变是折角本身和纹样（`cv-bands` / `cv-dots` / `cv-grid` / `cv-diag`）。
- 结论：按纯色 + inset 阴影还原；Meng 说的“上下带一点深浅变化、底部略深”是 inset 阴影 + 计数条叠加的视觉效果，不是底色渐变。已按此实现（§3 第 2 处）。

## 5. 深色模式

- 预览 HTML 里没有任何针对 `.nb-book` / 封面色的深色覆盖规则（深色规则只改其它组件）；封面在深浅模式下同色。Flutter 的 `CoverTokens` 本来就不分亮深，与预览一致，未改。
- 验证：深色与浅色各拍一套（`after-dark.png` / `after-light.png`），封面色、折角、书页边、计数条在两种模式下一致，只有页面底色/导航随主题变。

## 6. 样式 × 颜色组合与学科管理小预览

- 6 种样式（plain/lines/dots/grid/diagonal/double）× 7 色的规则未动（只叠纹样、底色不变）；重点验了斜纹黄（数学改 `diagonal` + `yellow`，深色）：`after-combo-dark.png`——斜纹在黄底上清晰、不显脏；折角、书页边、计数条在黄底上均正常。
- 学科管理页 52×68 封面小预览（`QmCoverMini`，`lib/widgets/uikit.dart`）是**独立 widget + 独立画笔 `_QmCoverMiniPainter`**，与书架 `_buildBook` 不共用绘制代码；本次改动不影响它，未动它。报告注明：若以后要统一，小预览需单独按同一套画法重画（不在本次范围）。

## 7. 遗留与未动点（不在本次 6 处内，记下来不自己定）

1. `double`（双线框）样式仍显示折角：HTML 里 `cv-frame` 会藏折角（`.cv-frame .nb-book-fold{display:none}`）且虚线内框改成 3px 双线；Flutter 里 `double` 仍画折角 + 虚线内框。这是样式保真度的既有偏差，本次未动（任务书只要求 6 处 + 保持样式规则）。
2. 内阴影左暗带大部分被 11px 书脊盖住，只在脊边透出一点——与 HTML 绘制顺序一致，不是 bug。
3. 折角阴影的横向偏移：HTML 是 -2px，Flutter `drawShadow` 只能下移、横向取 0；2px 差别在 4px 模糊下不可见。

## 8. 验证

### flutter analyze / 测试

- `flutter analyze lib/modules/wrongbook/wrongbook_page.dart test/wrongbook_page_test.dart`：**0 问题**（改前基线也是 0）。
- 针对性测试 `flutter test test/wrongbook_page_test.dart`：**42/42 通过**（基线 41 项 + 新增 1 项）。
- 新增回归测试（书架组）：「书架封面按预览画法：名下移、书页边/内阴影/折角/虚线框齐全」——断言三本书各一套绘制层（`_CoverPatternPainter` / `_CoverInsetShadowPainter` / `_DashedBorderPainter` / `_CoverPageEdgePainter` / `_CoverFoldPainter` 各 3 个）、40.4px 占位各 1 个、计数条深色半透明底 + 白 .35 边框 + 圆角 12 各 1 个、副标题 opacity .95 与字距 13.6、计数标签 opacity .92；无英文断言仍由原测试覆盖。悬停只由截图验证（widget 测试不模拟鼠标悬停）。
- 全量测试：`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux flutter test`：**575 项全部通过**（含新增 1 项）。注意：不设 `LD_LIBRARY_PATH` 时 `p05_image_pipeline_e2e_test.dart`（phase=write）会失败，报错“缺原生库时设 LD_LIBRARY_PATH 再跑”——与封面无关，是环境变量问题；按测试文件头注释设好后通过（真实推理 16 框）。

### 截图（`docs/ui-replication/shots/b2-wrongbook-cover/`，Xvfb 1280×720，标准字号）

| 文件 | 内容 |
| --- | --- |
| `before-dark.png` / `before-light.png` | 改前，深色/浅色（迁移后 v2 演示库，见 §9） |
| `before-combo-dark.png` | 改前，数学斜纹黄，深色 |
| `before-hover-dark.png` | 改前，鼠标移到数学书上（无上移） |
| `before-*-empty-library.png` | 改前第一轮：v1 演示库被应用删库后重建为空库的截图（0 题、浅色，见 §9） |
| `after-dark.png` / `after-light.png` | 改后，深色/浅色 |
| `after-combo-dark.png` | 改后，数学斜纹黄，深色 |
| `after-hover-dark.png` | 改后，悬停数学书（上移 4px，书顶 158→154） |
| `compare-dark.png` | 预览 / 改前 / 改后三联（数学书裁剪，等高并排） |
| `compare-light.png` | 改前 / 改后两联（浅色数学书） |
| `fold-compare.png` | 折角特写三联：预览 / 改前 / 改后 |
| 截图脚本 | `docs/ui-replication/run-shots-b2-wrongbook-cover.sh`（`before\|after`；支持 `B2_BIN` / `B2_DEMO` 环境变量指定二进制与演示库） |

### 像素实测（`after-dark.png`，数学书：书体 x 246–556、顶 y=158）

- 蓝 `#2F7CF6`（取样 `47,124,246`）；计数条区 `(38,99,197)` = 蓝 × 0.8（黑 .20 叠加）。
- 学科名：字墨顶 y≈232（书顶 +74px，目标 74.4px）；字墨中心与书中心基本重合。
- 副标题：字墨中心偏移 +4.5px（预览同法测量 -2px，见 §3 第 6 处）。
- 计数：数学 2/2/0、英语 2/0/1、政治 1/0/0，与迁移后演示库一致；与预览的 3/3/0 不同是演示数据本身（演示库数学只有 2 道已整理题），不是画法问题。

## 9. 环境发现（需协调员知晓，影响三名工人的截图验证）

1. **B2-start 演示库是 v1 库，应用一启动就把它删了。** `~/workspace/demo-db-backup/quiz-master2.db.b2-start`（md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`）的 `PRAGMA user_version = 1`；而应用 `schemaVersion = 2`，按 §6 第 1 条（老库直接删、不迁移）启动时删除 v1 文件并重建空 v2 库（不预置演示题）。这解释了第一轮截图全是 0 题、深色也渲染成浅色（新库 `themeMode` 默认 `system` → Xvfb 下为浅色）。P0B2 当时用的库（md5 `6801a73b…`）是 v2 且有演示题，所以能看到计数与深色。
   - 本次的办法（仅用于截图验证，不动原库）：把 v1 副本按 `createTables` 的 v2 DDL 就地升级——补 questions 7 列（`source_path/source_kind/source_page/page_image_path/slice_path/slice_width/slice_height`）、collect_tasks 2 列（`source_path/page_rotations`）、建 `question_boxes` 表及 4 个索引、`settings` 补 `schemaVersion='2'`、`PRAGMA user_version=2`——得 `/tmp/qm2-v2demo.db`（9 题、深色、数学蓝/plain）。截图用的就是它；每次跑完都把 live 库恢复为 v1 原库并核对 md5（见下）。迁移脚本 `/tmp/migrate-v2demo.sh`。**建议协调员确认：B2 的截图验收是否都走这个迁移库，还是由协调员另外提供 v2 演示库。**
2. **live 库在任务中途被改过字节（逻辑内容未变，已恢复验证）。** 全量测试会删库（已知 `p0_hardening_test` §4.1 单例测试），每次跑完我都从自己的备份恢复并核对 md5；但有一次在 `after` 截图脚本启动时发现 live 库 md5 变成了 `f14cf960…`（dump 与备份逐行一致，应是某次测试/应用打开单例时写了元数据或同值行；其后又变回 `8f7f9c…`，疑似另一名工人同期恢复了它）。最终状态已核对：live 库 md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`，与协调员备份一致，v1、9 题、深色。
3. **release 二进制在 11:31 被截断成 0 字节。** `build/linux/x64/release/bundle/quiz_master2` 在 11:31 变为空文件（0 字节可执行，shell 当空脚本跑、静默 0 退出），导致其后两次探测截图全是空白。应是同期有别的 worker 在同一树里构建/清理。为避开争用，改前二进制改在隔离树 `~/workspace/qm2-before-tree/`（复制当时工作树，不含 `build/`，`flutter build linux --release` 通过）里构建；改后二进制在本树构建，构建前确认无别的 worker 正在构建。隔离树可删（未进仓库）。

## 10. 需要 Meng 决定的地方

- 无。本次全部按预览值与既定决定执行（英文不恢复是他已定的；渐变按两版 HTML 核对结果执行；副标题 padding 按实测取 0）。若他想要 `double` 样式也按 HTML 藏折角，另立一项再做。
