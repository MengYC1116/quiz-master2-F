# R11-REPORT — 最终验收报告

- 分支：`ui-replication`（基线 `0c81217242c20fa4438e04db4ebabc92f2c0ddd1`）
- 视觉基准：`~/workspace/your_files/quiz-master2-jiao-hu-yuan-xing/quiz-master2-jiao-hu-yuan-xing.html`，SHA256 `18c8c43485a7831cec22e3d4fff659d7ea39754219b391874f0c5a88f50135e1`（**R11 验收时重新核对一致**）；完整预览 `quiz-master2-quan-xin-she-ji-yu-lan.html`，SHA256 `fe4a8e2630cc122f2587a4f147f6fb00f41b00874356692f1b1da1122a69fe86`（**重新核对一致**）
- 验收方式：**只读验收**。验收员未改任何业务/UI 代码（唯一写入：本报告、`docs/ui-replication/run-regress-r11.sh`、`docs/ui-replication/shots/r11/` 回归截图）。未 commit、未 push、未升级依赖、未改 `pubspec.lock`、未改 Schema。
- 验收日期：2026-11-13；环境：Linux 虚拟机，Flutter 3.47.9 / Dart 3.13.7（`~/workspace/flutter-install/flutter/bin/flutter`），Xvfb 1280×720。
- **结论：有条件通过**（理由见文末 §0；Linux 结果不能替代 Windows 11 最终验收）。

## 0. 验收结论

**有条件通过。**

- 通过的部分：R1–R10 的全部交付物都在工作树内，九页 + 外壳 + Tokens/UI Kit 均已按 HTML 原型重建；R11 全量重跑 `flutter analyze` 0 问题、`flutter test` **276/276 通过**、`flutter build linux --release` 成功；R11 九页导航回归亮/深各一遍（26 张截图）无崩溃、无白屏、无溢出；抽查的 HTML/Flutter 并排对照图结构、样式、文案一致，剩余差异均为各阶段报告已记录的已知项；Git diff 相对基线 15 个已跟踪文件 +13450/−5184，无 commit、无 push、`pubspec.lock` 零改动、Schema 零改动（`database.dart` 仅 +35 行新增查询）。
- 有条件的原因（均非 R11 新发现的阻塞项，而是贯穿各阶段的已知遗留）：
  1. **Linux 结果不能替代 Windows 11 最终验收**（见 §9）：字体、窗口尺寸、DPI、SQLite 原生资源、Windows Release 构建、两个同名 `.onnx` 模型接入、onnxruntime 版本锁定（D-07）全部待 Win11 真机。
  2. **放大浮层 1.5× 初始偏移未修**（R7/R8 遗留，另立项）：整理台/详情/复习三页共用 `showQuestionZoomDialog`，打开时纸面左偏，个别情况左侧文字被裁；拖动/滚轮缩放/关闭正常。
  3. **R0 §6-B 四项业务问题冻结未动**（报告范围口径、新增学科不同步、启动页未被消费、通知/备份不完整），等负责人裁决。
  4. 导航选中项偶现纯白（深色）pill（R9/R10 遗留，R11 回归中在深色复习页复现一次，根因未定，见 §3）。
  5. 分页 / 真实 YOLO / 真实图片切片 / 系统拖放未在真实条件下验证（见 §8）。

## 1. 九页完成情况

逐页核对各阶段报告的完成清单与截图，R11 复核结论如下。验证用库为演示库（9 道题、待整理 4 道、已加入复习 7 道，`themeMode=dark` / `fontSize=standard`，验收前后均已核对恢复原状）。

| 页 | 阶段 | 报告完成清单 | R11 复核 |
|---|---|---|---|
| R1 Tokens / Theme / UI Kit | R1 | `DesignTokens`（917 行）+ `AppTheme` + `uikit.dart`（1789 行）；D1 深色纸面 `#D8DCE2`、D2 深色主色 `#7FA8D0`；三档缩放 1.00/1.15/1.30；学科色与封面色分离；`app_icon.ico` 补入（SHA-256 `c098d3fc…69cbf8`，R11 复核一致） | 属实。R11 grep 核对 `design_tokens.dart`：深色 `paper #D8DCE2`、`accent #7FA8D0`、浅色 `accent #2E7CF6` 均在；R1 截图 `shots/r1-tokens/`、`shots/r1-uikit/` 4 张在库 |
| R2 外壳导航 | R2 | `app_shell.dart`（577 行）7 项主导航 + 底部 side-foot（学科速览 + 设置）；折叠 64px；角标口径沿用基线；内容区 padding 26/30 | 属实。R11 回归 26 张截图中外壳在每页均正常渲染；导航 7 项 + 底部设置齐全；角标 4/4 与库内实算一致；R2 截图 15 张在库 |
| 首页 | R3 | layout C 焦点大卡片（整卡可点去复习、46px 大数字、待解决/复查拆分、继续上次条）、下方 4 格、空状态、错误态横幅开关 | 属实。R11 回归深/亮首页均显示“3 道要复习 · 待解决 2 道 · 复查 1 道”、继续上次“整理工作台 · 数学「函数极限」”、四格数字与库内实算一致；R3 截图 11 张在库 |
| 收集中心 | R4 | 6 态任务行、导入学科下拉、拖放区、修框编辑器（两级框、内框模式、旋转整页、页缩略图条）、>3 任务内部滚动 | 属实。R11 回归收集页正常进入；R4 截图 16 张（含编辑器亮/深、内框模式）在库；报告 §4 的三处真问题均有回归测试覆盖 |
| 整理工作台 | R5 | H 布局（左图右表单）、队列 D 弹窗、批量浮动条、修框切片默认展开、放大浮层绕中心 1.5× | 属实。R11 回归深色整理页：队列“还剩 4 道”、当前“政治 · 材料分析：中国式现代化”、左图 stem 虚线框、右表单文件夹段展开、“必填已齐”，无溢出；R5 截图 14 张在库。注意：R5/R6 的深色截图因 R7 纸面改动（白 → `#D8DCE2`）已过期，R11 新截图已确认新渲染 |
| 错题本 | R6 | 书架 / 目录 / 列表 / 已归档四视图；封面 6 样式 × 7 色；文件夹树；D 折叠筛选；分页 10/20/30/40/50；批量模式 | 属实。R11 回归链路书架 → 目录 → 列表均正常；深色列表截图：工具栏单行、2 张大卡片 + 序号圆盘、分页器“共 2 道 · 第 1 / 1 页 每页 10 道”；R6 截图 40 张（含 HTML/Flutter 对照 6 张）在库 |
| 题目详情 | R7 | 方案 2 分段折叠式（答案解析 / 题目信息 / 复习记录）、工具栏 + 上一题/下一题、编辑态、删除内联确认、加入/取消加入复习 | 属实。R11 回归详情页（推送全窗路由、无左导航）：“第 1 / 2 题 · 按错题本当前的顺序”、标题 + ☆、三段全折叠、深色纸面 `#D8DCE2`；R7 截图 35 张（含对照 6 张）在库 |
| 复习 | R8 | 学科 × 错因分组列表、按题分块四步会话（看错因 → 写补救 → 重做 → 自查）、恢复条、已治愈组、总结页 | 属实。R11 回归深色复习列表：3 组（数学 概念不清 待解决 / 英语 概念不清 复查·已解决 / 数学 计算错误 解决中）、元信息“待解决/解决中 2 条 · 复查 1 条 · 已解决 0 条”、分页、未加入盒；R8 截图 43 张（含对照 8 张）在库 |
| 学习报告 | R9 | 范围条（本周/本月/全部）+ 核心数条 + “接下来练什么”一句话 + 弱点 Top 5 两列 + 学科分布；点行进错题本带学科 + 筛选 | 属实。R11 回归报告页正常进入；R9 截图 31 张（含对照 4 张）在库；回归脚本曾验证点弱点行 → 数学目录 → 筛选（已选 1）列表 |
| 学科管理 + 设置 | R10 | 学科管理四段折叠（学科/知识点树/标签/试卷）+ 封面样式块；设置五组折叠（外观/复习/错题本/数据/启动与关于）；`QmTextField` / `QmCoverMini`；`renameChapter` / `deleteChapter` 查询 | 属实。R11 回归两页默认态（全折叠）正常进入；R10 截图 49 张（含对照 9 张）在库；D5 核对结论属实：Flutter 学科管理里本无换图标/隐藏/排序逻辑，无代码可删 |

累计截图：`docs/ui-replication/shots/` 下 261 张 PNG（含 r0–r10 各阶段截图与对照图，另加 R11 回归 26 张）。

## 2. HTML 与 Flutter 视觉对照

### 2.1 对照图盘点

| 阶段 | 并排对照图（HTML 在上、Flutter 在下） | R11 抽查 |
|---|---|---|
| R2–R5 | 无 Playwright 并排图；对照方式为逐条 HTML CSS 规则 → Flutter 截图实测值（各报告 §5 对照表） | 抽查了各报告对照表与 R11 新截图，结论与报告一致 |
| R6 错题本 | 6 张（书架/目录/列表 × 亮/深） | 抽看 `compare-shelf-light.png`：结构/样式/文案一致 |
| R7 题目详情 | 6 张（默认亮/深、答案、信息、复习、编辑） | 抽看 `compare-detail-light.png`：结构/样式/文案一致 |
| R8 复习 | 8 张（列表亮/深、看错因、写补救、重做、重做已显、自查、总结） | 抽看 `compare-list-light.png`：结构/样式/文案一致 |
| R9 学习报告 | 4 张（默认亮/深、本月展开、空态） | 未抽看单张（报告对照表 + R11 回归复核） |
| R10 学科管理 + 设置 | 9 张（学科默认亮/深、封面、知识点树、试卷搜索、设置默认亮/深、外观、复习） | 未抽看单张（报告对照表 + R11 回归复核） |
| 合计 | **33 张并排对照图** | 抽查 3 张亮色（每页至少 1 张亮色 + 1 张深色的要求：R6/R7/R8 的深色对照图在各报告中有逐项文字结论，R11 回归亮/深 26 张新截图补足了深色实测） |

### 2.2 抽查结论：一致

三张抽查的对照图（错题本书架亮色、题目详情亮色、复习列表亮色）均为：标题/结构/文案/配色与 HTML 原型一致，数字差异只因 HTML 是静态演示数据（9 道题全已整理、DEMO_TODAY 2026-11-11）而 Flutter 用真实演示库（9 道题、待整理 4 道）。

### 2.3 剩余差异（均为各阶段报告已记录、R11 复核仍在的已知项，非新发现）

| # | 差异 | 来源 |
|---|---|---|
| 1 | 数字不同：HTML 演示数据 vs Flutter 真实库（书架计数、复习组数、报告核心数等） | 各阶段报告；对照只看结构/样式/文案 |
| 2 | HTML 页内长段设计说明文字不抄入应用（首页焦点卡自指说明、复习标题副标题、报告标题副标题等） | R0 附录 A2 + 各阶段报告；已定决策 |
| 3 | HTML 左导航无图标，Flutter 用 `QmGlyphs` 文字符号保留图标位（`⌂ ⇪ ✎ ▤ ↺ ▦ ☰ ⚙`）；全库无 `Icon`（R11 grep 核对：`Icon(` / `Icons.` 在 `lib/` 下 0 命中） | R2 报告 §3.1 |
| 4 | 题目详情是推送全窗路由、无左导航；HTML 详情在壳内带左导航 | R7 报告 §5（基线架构） |
| 5 | 详情副标题错因状态渲染为 pill，HTML 是纯文本；标准档副标题换两行 | R7 报告 §5 |
| 6 | 题图为占位切片的简化 CustomPaint 绘制，非 HTML 的完整手绘图；区域推导为已知近似（stem 恒有；含填空标记加 option；chart/timeline 加 figure） | R5 §6.2、R6/R7 报告；真实 YOLO 第 2 层接入后以模型框为准 |
| 7 | 复习标题 `复习` vs HTML `复习 · 解决错因`（副标题为设计说明，不抄） | R8 报告 §6.11 |
| 8 | 报告弱点并列行排序：HTML 中文拼音序，Flutter 码点序（Dart 无中文拼音排序）；只影响并列先后，不影响 Top 5 集合 | R9 报告 §6.5 |
| 9 | 封面样式存储 key 与 HTML 不同（plain/lines/dots/grid/diagonal/double vs plain/bands/dots/grid/diag/frame），标签中文相同，不改已存数据 | R10 报告 §3 |
| 10 | 导航选中项偶现纯黑（亮色）/纯白（深色）pill，代码写的是 accent 底；R11 回归深色复习页复现一次纯白，根因未定（疑似点击后的焦点高亮盖住底色） | R9 §6.9、R10 §6.5；R11 §3 复现记录 |
| 11 | 内容区底部 padding 微小偏差：HTML `.main` 为 `26px 30px 34px`（底部 34），token 按任务书口径取上下对称 26px | R2 §7.8、R3 §7.4 |

## 3. 交互验收结果

R11 九页导航回归（脚本 `docs/ui-replication/run-regress-r11.sh`，亮色与深色各一遍，标准字号，Xvfb 1280×720）：

| 步骤 | 深色 | 亮色 |
|---|---|---|
| 01 首页 | ✓ 焦点卡 3 道要复习 | ✓ 同左 |
| 02 收集中心 | ✓ 进入正常 | ✓ 同左 |
| 03 整理工作台 | ✓ H 布局、队列 4 道 | ✓ 同左 |
| 04 错题本书架 | ✓ 三本书 + 计数牌 | ✓ 同左 |
| 05 错题本目录 | ✓ 数学目录、文件夹树 | ✓ 同左 |
| 06 错题本列表 | ✓ 2 张大卡片、分页器 | ✓ 同左 |
| 07 题目详情 | ✓ 推送详情页、三段折叠 | ✓ 同左 |
| 08 返回列表 | ✓ 回到数学列表 | ✓ 同左 |
| 09 复习 | ✓ 3 组列表、未加入盒 | ✓ 同左 |
| 10 学习报告 | ✓ 范围条 + 核心数条 | ✓ 同左 |
| 11 学科管理 | ✓ 四段全折叠 | ✓ 同左 |
| 12 设置 | ✓ 五组全折叠 | ✓ 同左 |
| 13 回首页 | ✓ 首页计数不变 | ✓ 同左 |

- 截图：26 张，存 `docs/ui-replication/shots/r11/regress-dark/`（13 张）与 `regress-light/`（13 张），全部 1280×720。
- 像素复核：26 张均内容丰富（缩略图唯一色 180–827 色），深色平均 RGB 约 (35–114)，亮色约 (194–251)——**无崩溃、无白屏、无黑屏**；逐张目视抽查 7 张（深色首页/整理/详情/复习/列表、亮色首页/设置）无溢出黄条、无截断。
- 回归只做只读跳转，未点任何写操作按钮；跑完数据库已恢复原状（9 道题、`review_state` 为空、`themeMode=dark` / `fontSize=standard`，已核对）。
- **如实记录的既有行为（不是新发现）**：
  - 左导航学科速览“待整理 N · 待复习 M”在 216px 宽导航内换两行（Linux 回退字体 Noto Serif CJK 偏宽；Win11 用 Microsoft YaHei 时按字宽估算应为一行，须真机确认）——R2 遗留，各阶段报告均有记录。
  - 特大字号下左导航底部设置按钮需滚动才可见（导航列本身可滚动，无溢出）——R2 外壳设计，R5/R6/R9/R10 均有记录；R11 回归只跑标准字号，未重测特大档导航滚动（各阶段报告已有三档截图覆盖）。
  - 导航选中项偶现纯白（深色）：R11 深色回归第 09 步（复习页）截图中选中项呈纯白底深字，而同批深色首页/错题本列表截图中选中项为 accent `#7FA8D0` 底；亮色 13 张中选中项均为 accent 蓝底。属间歇性表现，根因未定，留待另查（见 §8）。
  - 详情页副标题标准档换两行（R7 已记录）。

## 4. 亮色、深色、三档字号验收结果

- **亮色 / 深色**：每页均有亮/深两套截图——R2 外壳 6 张、R3 首页 6 张正常态 + 2 张空状态、R4 收集 6 张 + 2 张空状态 + 4 张编辑器、R5 整理 6 张、R6 错题本 6 张书架/目录/列表 + 对照 6 张、R7 详情 6 张 + 对照 6 张、R8 复习 6 张 + 对照 8 张、R9 报告 6 张 + 对照 4 张、R10 学科/设置 12 张默认态 + 对照 9 张；R11 回归再补亮/深各 13 张。R11 抽查的亮/深截图底色、文字色、按钮色均与 token 一致（亮 `#2E7CF6` / 深 `#7FA8D0` 体系；深色纸面 `#D8DCE2` 在 R11 深色详情/整理/列表截图中均已确认）。
- **三档字号（1.00 / 1.15 / 1.30）**：各阶段均有亮/深 × 三档截图与 widget 测试“亮/深 × 三档无溢出”循环覆盖（每页测试文件均含该循环）；R11 全量测试 276/276 通过即包含这些循环。R11 回归本身只跑标准字号（1.00），大/特大档以各阶段截图 + 测试循环为准，未重拍。
- **字号缩放口径**：唯一映射 1.00/1.15/1.30，字号只在 `app.dart` 的 `MediaQuery TextScaler` 处乘一次，布局尺寸按 `qmScaleOf` 乘一次，不用 `Transform.scale`（各阶段报告一致口径，R11 未发现反例）。
- **字体说明**：Linux 截图里的字体是系统回退（Noto Sans/Serif CJK），不是 Win11 的 Segoe UI / Microsoft YaHei / Georgia；字号/行高结论在 Win11 上须复核（见 §9）。

## 5. flutter analyze 结果

```
$ flutter analyze
Analyzing quiz-master2-UI...
No issues found! (ran in 9.8s)
```

- R11 实测：**No issues found!** 与 R1–R10 每一轮的 analyze 结果一致。
- 附带输出：`14 packages have newer versions incompatible with dependency constraints`（`flutter pub outdated` 提示，受约束锁定，未升级，符合“不升级依赖”纪律）。

## 6. Linux Release 构建结果

```
$ rm -rf build/linux && flutter build linux --release
✓ Built build/linux/x64/release/bundle/quiz_master2
```

- R11 实测：构建前已 `rm -rf build/linux` 清旧 CMakeCache（R0/R4 已知问题），一次成功；产物 `build/linux/x64/release/bundle/quiz_master2`（23,840 字节 runner；`bundle/lib/libapp.so` 为本次构建）。
- Flutter/Dart 3.47.9 / 3.13.7，与基线锁定版本一致。
- **Linux Release 构建成功不等于 Windows Release 构建成功**：Windows 构建须在 Meng 的 Win11 机器上验证（见 §9）。`app_icon.ico` 已补入（SHA-256 `c098d3fc…69cbf8`，R11 复核与来源一致），但 Windows 构建仍未实测。

## 7. 回归测试结果

```
$ flutter test
01:33 +276: All tests passed!
```

- R11 全量重跑：**276/276 通过**，0 失败，耗时约 1 分 45 秒。
- 与 R10 报告的累计数一致（R10 交付时 276/276）。各阶段累计：R2 62 → R3 78 → R4 103 → R5 126 → R6 161 → R7 185 → R8 209 → R9 231 → R10 276。
- 测试文件 13 个（`test/` 下）：`app_shell_test`、`collect_page_test`、`detail_page_test`、`home_page_test`、`organize_page_test`、`report_page_test`、`review_page_test`、`settings_page_test`、`subjects_page_test`、`theme_smoke_test`、`uikit_test`、`widgets_forward_test`、`wrongbook_page_test`。覆盖：九页结构与业务口径（FakeRepo，不碰真实数据库）、亮/深 × 三档缩放无溢出、空状态/错误态、队列/批量/分页/会话四步/恢复条等关键交互。
- 覆盖边界（各阶段报告已说明，R11 不重复验证）：分页只在 widget 测试（12 道假题）里覆盖翻页，真实库每科只有 2–3 道已整理题；重复/超限黄色横幅（R4）、复习保存失败横幅（R8）、报告/学科管理/设置加载失败横幅（R9/R10）只在 widget 测试覆盖，真实窗口无故障注入入口；批量删除/归档/收藏等写操作只在 widget 测试覆盖，真实库截图流程只做读操作。

## 8. 未解决问题和已知限制

### 8.1 必须另立项修（验收员未改代码）

| # | 问题 | 来源 | 状态 |
|---|---|---|---|
| 1 | **放大浮层 1.5× 初始偏移**：`showQuestionZoomDialog` 打开时纸面左移，整理台/详情页曾出现左侧文字被裁，复习页左偏约 60–80px（该例文字未被裁切）；拖动/滚轮缩放/`+`/`−`/关闭/Esc 正常 | R5 §5.2（`_centerInitial` 未彻底修好）、R7 §6.3、R8 §6.2 | 未修，另立项 |
| 2 | **导航选中项偶现纯黑（亮色）/纯白（深色）pill**：代码写的是 accent 底，实际渲染间歇性为纯黑/纯白（疑似点击后的焦点高亮盖住底色，原因未定）；R11 深色回归第 09 步复现一次纯白 | R9 §6.9、R10 §6.5；R11 §3 复现 | 未修，另查 |

### 8.2 R0 §6-B 业务问题冻结清单（重构期间一律不动，等负责人裁决）

| # | 问题 | 位置 |
|---|---|---|
| 1 | 学习报告 `pendingCount` 不按时间范围过滤（`solvedCount` 与复查通过率按范围过滤，`pendingCount` 不按） | `report_page.dart`（R0 §6-B-1；R9 §6.2：切范围时“待解决错因”数字不变） |
| 2 | 学科管理新增学科不同步到首页 / 导航速览（`Subject.all` 写死三科，首页与导航速览遍历 `Subject.all` 而非数据库 `subjects` 表） | `models.dart`（R0 §6-B-2） |
| 3 | 设置“启动页”设置项未被消费（路由初始值写死 `'/home'`） | `app.dart`（R0 §6-B-3） |
| 4 | 通知提醒只有开关 + 时间字段，无任何通知调度实现；备份导出只含 8 张表，不含 `collect_tasks` / `review_state` / `review_history` / `recent_tasks`；缓存清理为启发式删除；数据库位置切换靠 `db_location.txt` 标记文件、不迁移旧库 | `database.dart` 等（R0 §6-B-4） |

### 8.3 其他已知限制与待定夺项

- **分页未在真实大数据量下验证**：真实库每科最多 2–3 道已整理题；分页（10/20/30/40/50）只在 widget 测试里覆盖。
- **真实 YOLO 未接入**：仍是占位实现（`yolo_onnx_service.dart`，`hasRealModel` 恒 false；`assets/models/` 只有 README）；onnxruntime 版本未锁定（D-07）；真实模型文件尚未接入。见 §9。
- **真实图片切片未验证**：图片切片为示意绘制（`widgets.dart` 的 `QuestionSlice` / `_SliceFigurePainter`）；修框全流程未用真实文件验证；`QuestionSlice(failed: true)` / `imageFailed` 失败占位在应用内无触发入口（无真实图片通道），只在组件/widget 测试级验证。
- **系统拖放导入未接**：拖放区只有诚实占位文案（“拖放导入还没接好，先点「选择文件」导入”）；「选择文件」导入可用；导入进度 Timer 模拟；加密 PDF 启发式判断。
- **最近任务 kind 中英文两套写法**：种子写 `'整理'`、线上代码写 `'organize'` / `'collect'`；R3 已在首页表现层归一化，未改数据层；是否统一数据层写法需定夺。
- **首页错误态无真实触发通道**：设置页备份失败后首页横幅靠 `HomePage(showBackupError:)` 开关触发，app 级接线未做，需定夺。
- **本周定义**：基线是本周一到今天，HTML 是今天往前 7 天；R9 沿用基线，需定夺。
- **已解决与复查通过率是近似口径**：模型无 cured 日期字段，以 `lastCheck` 近似；`review_history` 无复查备注字段，通过率以全部已判定自查记录近似。真要精确须加字段（改 Schema，不在本轮范围）。
- **复习列表包含已归档的已加入题**（HTML `qInReview` 排除已归档题；R8 沿用基线口径）；复查通过时 `recordSelfCheck` 会把 `solvedCount` 加到超过治愈次数（如 2→3，HTML 复查通过不加），属基线既有行为。
- **HTML 与模型之间的既有缺口（未动，不发明字段）**：HTML 自由文本“错误原因（错因）”与“收集文件”来源行无 Flutter 模型字段；HTML 详情编辑表单无题名栏，Flutter 保留基线题名编辑；q-math-2 边界（有文件夹但 `isOrganized=false`，按任务口径无“加入复习”按钮）；空章节存不下来（加章节须同时给第一个知识点，章节只随知识点存在）；`CompactSliceThumb` 仍白色，与 `QuestionSlice` 纸面改动不一致；删除最后一题 → pop 路径未做 widget 测试。
- **重复/超限黄色横幅无 widget 测试、无截图**（R4 §6.4）：实现已在，分支未覆盖。
- **`clampToPage` 贴边抛错是基线服务缺陷**：`YoloOnnxService.clampToPage` 要求宽/高至少 0.08，框贴右/下边时会抛 `ArgumentError`；编辑器内 `_clampBoxSafe` 已兜底，YOLO 服务本身未动。
- **R5/R6 的深色截图部分过期**：R7 把 `QuestionSlice` 纸面由纯白改为 `#D8DCE2` 后，整理台切片与错题本大卡片深色下同步变 `#D8DCE2`（更接近 HTML/D1），R5/R6 的深色旧截图已过期；R11 新截图已确认新渲染。
- **点段头后页面上滚约 136–158px**（焦点滚动，R1 共享组件既有行为，各折叠页都有）；**章节行只响应文字区**（与 HTML 行内按钮形态一致，不改）；**队列弹窗定高留白**（题少时列表区下方留白较多，HTML 也是 max-height 形态，可接受取舍）。
- **HTML 死代码不实现**（全程遵守）：不复活旧翻卡模型、不照搬静态演示数字、不实现学科管理死按钮（隐藏/换图标/排序）、不实现错题本学科筛选下拉、不把学科管理文件夹残留做成第五组、设计说明文字不抄入应用。
- **旧库 subjects 颜色仍是旧值**（R1-ISSUES 4-1）：R1 改了三科静态色值，种子只在建库时写入，已存在的数据库里 `subjects.color` 仍是旧值；是否迁移旧库数据属业务决策，未动。
- **关于页作者写死“作者：Meng”未核实**（R0 §6-C）。

## 9. Windows 11 待验证事项

**以下全部须在 Meng 的 Win11 真机上验证；Linux 结果不能替代。**

| # | 事项 | 说明 |
|---|---|---|
| 1 | Win11 字体 | Segoe UI / Microsoft YaHei / Georgia 在 Win11 真机上的实际显示效果。Linux 截图字体为系统回退（Noto Sans/Serif CJK），不是 Win11 效果；尤其各处 11–13px 小字、区域标签、导航速览行在微软雅黑下的行高与换行须真机确认（Linux 下速览行换两行、R5 标签裁切修法均按回退字体验证） |
| 2 | 窗口尺寸 | HTML 原型按 1280×800 及以上设计；真实窗口尺寸由用户设定；1280×720 以外尺寸、HTML 断点（整理 1102px、首页 900/560px）须真机复核 |
| 3 | DPI | DPI 缩放下的 token / 布局表现须真机看 |
| 4 | SQLite 原生资源 | Linux 库位置 `~/.local/share/quiz-master2/`；Win11 库位置 `%LOCALAPPDATA%\quiz-master2\quiz-master2.db`，原生资源须真机复核 |
| 5 | Windows Release 构建 | `flutter build windows` 在 Meng 的 Win11 机器上验证；`app_icon.ico` 已补入（SHA-256 `c098d3fc…69cbf8`），但 Windows 构建仍未实测 |
| 6 | 两个同名 `.onnx` 模型接入 | 两个独立的 `.onnx` 文件：一个检测单题（第 1 层整题框），一个检测题内结构（第 2 层，只含 stem / option / figure，不产生独立题目；每个选项 A/B/C/D 各为独立框，不合并为一个选项区）。两个文件名字一样，接入时**不能放在同一目录**，必须用文件夹区分（或等负责人提供文件后定重命名规则，**不要自己猜文件名、不要自己改名**）。等负责人提供模型文件后再处理 |
| 7 | onnxruntime 版本锁定（D-07） | 当前 Flutter 代码仍是占位实现，onnxruntime Dart 包版本未锁定，待 Win11 实测后定；真实模型接入与实测记为 Win11 待验证事项，不在 UI 重构范围内 |
| 8 | 真实文件全流程 | 真实 PDF/图片导入、真实图片切片、修框全流程、系统拖放导入在 Win11 真机上验证 |

## 10. 完整 Git diff 与文件变更清单

### 10.1 相对基线的 diffstat（R11 实测，`git diff --stat`）

```text
 lib/app.dart                                 |  338 +--
 lib/data/database.dart                       |   35 +
 lib/data/repository.dart                     |   10 +
 lib/models/models.dart                       |   32 +-
 lib/modules/collect/collect_page.dart        | 2700 ++++++++++++++----
 lib/modules/detail/question_detail_page.dart | 1661 +++++++----
 lib/modules/home/home_page.dart              |  800 ++++--
 lib/modules/organize/organize_page.dart      | 3043 ++++++++++++++------
 lib/modules/report/report_page.dart          |  872 ++++--
 lib/modules/review/review_page.dart          | 2217 +++++++++++----
 lib/modules/settings/settings_page.dart      |  778 +++--
 lib/modules/subjects/subjects_page.dart      | 1475 ++++++----
 lib/modules/wrongbook/wrongbook_page.dart    | 3925 +++++++++++++++++++-------
 lib/theme/app_theme.dart                     |  249 +-
 lib/widgets/widgets.dart                     |  499 +++-
 15 files changed, 13450 insertions(+), 5184 deletions(-)
```

### 10.2 新增未跟踪文件（`git ls-files --others --exclude-standard`）

| 类别 | 文件 |
|---|---|
| Tokens / UI Kit / 外壳（R1–R2 新增） | `lib/theme/design_tokens.dart`（917 行）、`lib/widgets/uikit.dart`（1789 行）、`lib/widgets/app_shell.dart`（577 行） |
| 测试（R1–R10 新增，13 个） | `test/app_shell_test.dart`、`test/collect_page_test.dart`、`test/detail_page_test.dart`、`test/home_page_test.dart`、`test/organize_page_test.dart`、`test/report_page_test.dart`、`test/review_page_test.dart`、`test/settings_page_test.dart`、`test/subjects_page_test.dart`、`test/theme_smoke_test.dart`、`test/uikit_test.dart`、`test/widgets_forward_test.dart`、`test/wrongbook_page_test.dart` |
| Windows 资源（R1 补入） | `windows/runner/resources/app_icon.ico`（33,772 字节，SHA-256 `c098d3fc85cacff98b8e69811b48e9f0d852fcee278132d794411d978869cbf8`） |
| 报告与脚本（R0–R11） | `docs/ui-replication/` 下全部报告（R0、R1-BASELINE、R1-ISSUES、R1-TOKENS、R1-UIKIT、R2–R11）、`run-shots-r*.sh` / `run-regress-r*.sh` 各轮脚本、`shots/` 287 张 PNG（含 R11 回归 26 张） |

### 10.3 纪律核对（R11 实测）

| 项 | 结果 |
|---|---|
| HEAD | `0c81217242c20fa4438e04db4ebabc92f2c0ddd1`（基线提交，未变） |
| commit / push | **无**（`git log --oneline -1` 仍为基线提交；工作树全部改动未提交） |
| `pubspec.lock` | **零改动**（`git diff -- pubspec.lock` 0 行） |
| Schema | **零改动**（`lib/data/database.dart` 仅 +35 行：新增 `renameChapter` / `deleteChapter` 两个查询，未改建表语句；无新增/修改字段，无版本变更） |
| 依赖 | 未升级（`flutter pub get` 提示 14 个包有更新版本但受约束锁定） |
| 业务口径 | 九页业务语义沿用基线 repository 口径；R0 §6-B 四项冻结未动；R5 的两处有意小修（`clearExamId` 使“未归属试卷”真能清空；主表单删除按钮移除）已在 R5 报告列出备查 |
| 验收员改动 | 仅本报告、`run-regress-r11.sh`、`shots/r11/` 26 张截图；未改任何业务/UI 代码 |

---

**验收员签字**：R11 最终验收完成。UI 重构范围（R1–R10）已按 HTML 视觉基准完成并在 Linux 上验证通过，结论为**有条件通过**，条件为 §0 所列 5 项（核心是 Win11 真机最终验收 + 放大浮层偏移另立项修 + R0 §6-B 业务问题待裁决）。验收后状态：真实库已恢复原状（9 道题、待整理 4 道、已加入复习 7 道，`themeMode=dark` / `fontSize=standard`）；未 commit、未 push。
