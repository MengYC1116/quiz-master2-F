# R3 报告 — 首页重建（layout C 焦点大卡片）

> 阶段：R3（首页）。只改 `lib/modules/home/home_page.dart` 及首页必需的
> 最小共享改动（`lib/theme/design_tokens.dart` 增加首页实读度量）；
> 其他八页、`lib/data`、`lib/services`、`lib/models` 的业务语义一个字
> 未动；数据库 Schema、Repository 口径、业务规则 / 状态机未动；
> 未升级依赖、未改 `pubspec.lock`、未 commit、未 push。
> 视觉基准 SHA256 已核对一致：交互原型
> `18c8c43485a7831cec22e3d4fff659d7ea39754219b391874f0c5a88f50135e1`。
> R1/R2 的未提交改动仍在同一工作树内；以下 diffstat 只列 R3 直接改动
> 的已跟踪文件（`design_tokens.dart` 是 R1 新增未跟踪文件，R3 的
> token 增量不体现在 `git diff` 里，见 §1）。

## 1. 修改文件清单

| 文件 | 改动 |
|---|---|
| `lib/modules/home/home_page.dart`（重写，263 → 715 行） | 按 HTML `viewHome` / `viewHomeC` / `homeCBottomHTML` 重建：问候语 24px/800 + 副标题“上次停在：…”；焦点大卡片 layout C（整卡可点去复习，46px/800 大数字 + 待解决/复查拆分，下半部“继续上次”条 + stopPropagation 按钮）；下方 4 格（快速收集 + 三科各一格）；空状态中性卡片；错误态顶部红色横幅（`showBackupError` 开关，见 §6）；去掉页内边距（外壳 26/30 不再叠加）；全部取 DesignTokens 与 UI Kit，全库无 `Icon` |
| `lib/theme/design_tokens.dart`（改，+22 行） | 新增“首页实读度量”一节：焦点卡 padding 26/28、margin-bottom 14、kicker 13px、明细 14.5px、继续条 margin-top 18 / padding-top 16 / gap 14、空状态数字 28px、副标题下边距 20、分区标题 13px、四格 padding 14/16 与 gap 12（全部注明 HTML 选择器来源） |
| `test/home_page_test.dart`（新增，340 行，16 个） | 焦点卡点整卡去复习、继续按钮 stopPropagation、空状态、错误态、亮/深、三档缩放无溢出、页内无边距、不用图标字体（FakeRepo 覆盖 repository 调用，不碰真实数据库） |
| `docs/ui-replication/run-shots-r3.sh`（新增） | 6 张正常态 + 2 张空状态截图脚本（亮/深 × 标准/大/特大；空状态改库前整库备份、跑完恢复原库文件） |
| `docs/ui-replication/run-regress-r3.sh`（新增） | 导航回归脚本：点复习页再点回首页 |
| `docs/ui-replication/shots/r3/`（新增，11 张） | 6 张正常态 + 2 张空状态 + 1 张错误态 + `regress/` 2 张 |
| `lib/showcase_home_error_main.dart`（临时，已删除） | 仅用于错误态截图的展示入口（R1 同款做法），截图后已删除，并已重新 `flutter build linux --release` 恢复真实应用产物 |

`git diff --stat`（仅 R3 直接改动的已跟踪文件）：

```text
lib/modules/home/home_page.dart | 800 ++++++++----------------------------------
 1 file changed, 626 insertions(+), 174 deletions(-)
```

`windows/runner/resources/app_icon.ico` 未动（SHA-256 仍为
`c098d3fc85cacff98b8e69811b48e9f0d852fcee278132d794411d978869cbf8`）。

## 2. 结构说明

### 2.1 首页结构（HTML 选择器 → Flutter 落点）

| HTML | Flutter 实现 |
|---|---|
| `h3.pt` 问候语 24px/800 | `Text(settings.greeting)`，`pageTitleFontSize` 24 / w800（不是 34px 的 `.ahead h1`；旧首页误用 `headlineMedium` 34px，已改） |
| `.psub` 副标题 13.5px muted，`margin:3px 0 20px` | `上次停在：{页面名} · {学科}「{标题}」`；无最近任务时为“上次停在：还没有记录” |
| `.focus-card`（2px accent 边、accent-soft 底、radius-lg 16、padding 26×28、margin-bottom 14） | `InkWell`（整卡可点去复习）+ `Container`；kicker“要复习的题”13px/800、字距 .08em、accentText（**不抄**原型里的自指说明“点这张卡片去复习页……”）；大数字 `N 道要复习` 46px/800/行高 1.15；明细 14.5px ink-2 |
| `.fc-continue`（margin-top 18、padding-top 16、1px line-strong 顶边、gap 14） | 小伙伴 `CompanionWidget` + 11.5px 气泡语（surface 底 + line 细边 + 999 圆角，按 HTML `.buddy-say` 单画）+ 标题 15px/700 + 说明 12.5px muted + `QmButton` 主按钮「继续上次」；按钮在 `InkWell` 内层，手势竞技场内层优先，点按只走最近任务、不触发整卡去复习（测试覆盖，见 §5） |
| `.secttl`“快速收集与各学科待复习概览”13px/700、字距 .08em | 分区小标题，margin-top 22 / bottom 4（焦点卡 margin-bottom 14 另计） |
| `.c-bottom` 4 列 gap 12、`.c-mini`（1px line 边、radius 12、padding 14×16、surface 底） | `LayoutBuilder`：宽 >900px 4 列、>560px 2 列、否则 1 列（与 HTML `@media 900/560` 断点一致）；`IntrinsicHeight` + `Row(stretch)` 使四格等高（滚动视图内高无界，`Row(stretch)` 直接用会报“infinite height”，见 §5）；学科格用学科 soft 底 + 学科 ink 色标题；标题 15px/800、说明 12.5px muted、按钮行 gap 8 可换行 |
| `.focus-card.no-due`（line-strong 细边、surface-2 底、居中、不可点） | 空状态卡：小伙伴 + 气泡“今天休息一下”+ 28px“今天没有要复习的，明天再来吧”+ 明细“要复习 0 道 · 没有待解决的错因，也没有到复查时间的题”；下方 4 格照常显示 |
| `.banner.err`（手动备份失败） | `QmBanner(tone: error)`，文案为原型 `viewHome` 的 `errBanner` 原文，右端「知道了」可关闭；见 §6 的触发方式说明 |

### 2.2 业务口径（沿用 repository 现有口径，未改 repository）

- **要复习数**：`homeRevCounts()` / `dueToday()`（手动加入复习且已整理
  且至少一个错因未解决或已到复查时间，数题不数错因），与导航速览同一口径。
- **待解决 / 复查拆分**：按 HTML `homeRevCounts`——有未解决错因的题计
  待解决，只有复查到期的题计复查，两者之和 = 要复习总数。本页用
  `dueToday()` + `causeRecords()` 现算（不改 repository）；复查为 0 时
  明细只写“待解决 X 道”（与 HTML 的条件渲染一致）。
- **继续上次**：`recentTask()` 的最近任务；无记录时默认去复习（沿用
  基线 `_resumeRecent` 的 fallback）。**发现并处理的一处基线不一致**：
  演示数据种子（`database.dart` 的 `_seedDemo`）写 `kind: '整理'`（中文），
  而线上代码写 `'organize'` / `'collect'`（英文），基线 switch 只认英文，
  种子行会误落到默认“复习”。本页在表现层把两边都认（`'organize'/'整理'` →
  整理工作台，`'collect'/'收集'` → 收集中心），不改 repository 与种子；
  详见 §7 第 2 项。
- **待整理**：`pendingOrganizeBySubject()` 按学科实时算，不照搬 HTML
  写死的演示数字“待整理 3”。
- **快速收集**：只做文件导入入口（「去收集中心」进收集页），不加手动录入；
  格内说明为 HTML `homeCBottomHTML` 原文（“只有一个入口：导入文件
  PDF / JPG / PNG，导入后自动框出整题（手机拍的照片先传到电脑，再当普通
  文件导入）”）。
- **问候语**：取设置里的 `greeting`（默认“今天也要加油呀”），设置存储不动。
- **无最近任务**：副标题“上次停在：还没有记录”；继续条标题“继续上次：
  还没有记录”、说明“先去收集第一道题吧”、按钮变为「去收集」（去收集页）。

### 2.3 页内边距（R2 遗留收口）

- 本页 `SingleChildScrollView(padding: EdgeInsets.zero)`，不再带 24–28px
  页内边距；总缩进落到外壳的准确 26/30（测试断言覆盖）。
- HTML `.main` 底部是 34px，token 仍按任务书口径取上下对称 26px（R2
  报告 §7 第 8 项）；首页先按外壳 token 走，底部差异记入 §7 第 1 项，
  未擅自改为 34。

### 2.4 Token 来源

颜色、字号、圆角、间距全部取自 `DesignTokens`（R1 已核对的 HTML
`:root` / 深色 `@media` 值）与 §1 新增的首页实读度量；按钮用
`QmButton`（主 / plain 小按钮）、横幅用 `QmBanner`、小伙伴用
`CompanionWidget`（气泡语按 HTML `.buddy-say` 单画，见 §2.1）。
字号只写基准值，由 app.dart 的 `MediaQuery TextScaler` 全局缩放一次；
布局尺寸按 `qmScaleOf(context)` 的同一因子乘一次。不重复缩放，
不用 `Transform.scale`，不用图标字体（测试断言 `find.byType(Icon)` 为空）。

## 3. 测试与构建结果

| 检查 | 结果 |
|---|---|
| `flutter analyze` | **No issues found!** |
| `flutter test` | **78/78 通过**（R1+R2 的 62 个 + R3 新增 16 个） |
| `flutter build linux --release` | **成功**：`✓ Built build/linux/x64/release/bundle/quiz_master2`（错误态截图后已重建正式产物，见 §4.3） |

新增测试覆盖（`test/home_page_test.dart`，FakeRepo，不碰真实数据库）：
问候语 + 副标题 + 焦点卡数字与拆分、自定义问候语取自设置、点焦点卡
数字去复习、点「继续上次」只走最近任务且不触发整卡去复习、下方 4 格
数字与三个按钮、无复查时明细只写待解决、空状态文案与不可点、无最近
任务 fallback 为去收集、错误横幅显示与「知道了」关闭、平时不显示错误
横幅、亮/深焦点卡底色与边框色、亮/深 × 三档缩放无溢出、空状态 × 三档
缩放无溢出、页内无边距、首页不用图标字体。

**测试中发现并修复的两个真问题**（均已修完、测试覆盖）：
1. **滚动视图内 `Row(stretch)` 报 infinite height**：下方 4 格的
   `Row(crossAxisAlignment: CrossAxisAlignment.stretch)` 在纵向滚动视图
   （高无界）里布局时抛 `BoxConstraints forces an infinite height`，
   首轮 16 个新测试全灭。修复：`IntrinsicHeight` 包裹 Row 再拉伸等高
   （HTML `.c-bottom align-items:stretch` 的等效做法）。
2. **亮/深底色测试的查找歧义**：`find.descendant(..., Container)` 命中
   卡内多个 Container（卡片体、继续条顶边容器、气泡容器）。修复：给
   焦点卡体加 `Key('home-focus-card-body')` 直查。

## 4. 截图对照（Xvfb 1280×720，Release 产物）

截图脚本：`docs/ui-replication/run-shots-r3.sh`（6 张正常态 + 2 张空状态，
改 settings 表与 `review_joined` 前整库备份、跑完恢复原值/原库文件）、
`docs/ui-replication/run-regress-r3.sh`（点复习页再点回首页）。
本机无 headless 浏览器，无法直接渲染 HTML 原型做像素并排；对照方式为
逐条 HTML CSS 规则 → Flutter 截图实测值（与 R2 同款做法）。

验证用库（`~/.local/share/quiz-master2/quiz-master2.db`，R1 留下的演示库，
9 道题）：数学已整理已加入 2 道（概念不清待解决、计算错误解决中）、
英语已加入 1 道（概念不清已解决、复查日昨天，已到复查时间）、政治已加入
的题均未整理；待整理数学 1 / 英语 1 / 政治 2；最近任务为种子行
（整理 · 数学「函数极限」）。截图前已备份到 `/tmp/qm2-db-backup-r3.db`，
验证后 settings 已恢复 `themeMode=dark` / `fontSize=standard`，
`review_joined=1` 的题数恢复为 7。

### 4.1 正常态 6 张（`docs/ui-replication/shots/r3/`）

| 截图 | 路径 |
|---|---|
| 亮色标准 | `home-light-standard.png` |
| 亮色大 | `home-light-large.png` |
| 亮色特大 | `home-light-extraLarge.png` |
| 深色标准 | `home-dark-standard.png` |
| 深色大 | `home-dark-large.png` |
| 深色特大 | `home-dark-extraLarge.png` |

对照结论（HTML 规则 → 截图实测，库内实算数字全部一致）：

| HTML 规则 | 实测 |
|---|---|
| 问候语 24px/800 + 副标题“上次停在：…” | “今天也要加油呀”24px；副标题“上次停在：整理工作台 · 数学「函数极限」”（种子 kind `'整理'` 经 §2.2 的归一化正确显示为整理工作台，而非基线的误判“复习”） |
| 焦点卡 2px accent 边 + accent-soft 底 + 46px 数字 | 亮 `#2E7CF6` 边 + `#E1EDFF` 底、“3 道要复习”46px；深 `#7FA8D0` 边 + `#2C3949` 底、主按钮 `#7FA8D0` + `#131A24` 深字 |
| 明细“待解决 X 道 · 复查 Y 道” | “待解决 2 道 · 复查 1 道”（数学 2 道有未解决错因、英语 1 道仅复查到期，与库内实算一致；与导航速览合计一致） |
| 继续上次条（小伙伴 + 文字 + 主按钮） | 小伙伴 + 气泡“上次到这里”、标题“继续上次：整理工作台 · 数学「函数极限」”、说明“上次停在待整理队列的这道题”、右侧「继续上次」主按钮 |
| 下方 4 格 + 每格“要复习 N 道 · 待整理 M 道” | 快速收集 + 数学“要复习 2 道 · 待整理 1 道”+ 英语“要复习 1 道 · 待整理 1 道”+ 政治“要复习 0 道 · 待整理 2 道”，与 `homeRevCounts` / `pendingOrganizeBySubject` 的库内实算一致；学科格底色为学科 soft 色、标题为学科 ink 色（深色下底色塌成 `#262B33`、只靠标题色区分，与 HTML 深色行为一致） |
| 内容区总缩进 26/30 | 页内边距已去掉；问候语左缘与导航内容区左缘对齐，落到准确的 26/30（旧首页 28px 页内边距已清零，见 §3 测试断言） |
| 三档缩放 | 1.00/1.15/1.30 下导航宽、字号、按钮、卡片同步放大，无截断、无溢出黄条；特大档下半部四格超出 720 高，整页滚动可达（无固定高度内滚容器，与 HTML 整页滚动一致） |
| 亮/深两套主题 | 6 张截图亮/深底色、文字色、按钮色均与 token 一致 |

### 4.2 空状态 2 张

| 截图 | 路径 |
|---|---|
| 亮色标准（空状态） | `home-empty-light-standard.png` |
| 深色标准（空状态） | `home-empty-dark-standard.png` |

对照结论：焦点卡变中性样式（亮：surface-2 暖纸底 + line-strong 细边；
深：surface-2 `#21262E` 底 + line-strong 边），居中显示小伙伴 + 气泡
“今天休息一下”+ 28px“今天没有要复习的，明天再来吧”+ 明细“要复习 0 道 ·
没有待解决的错因，也没有到复查时间的题”；下方 4 格照常显示，各科要复习
均为 0 道、待整理数不变（数学 1 / 英语 1 / 政治 2）；副标题仍显示最近
任务（最近任务还在，只是不再有要复习的题）。

### 4.3 错误态 1 张

| 截图 | 路径 |
|---|---|
| 深色标准（错误态） | `home-error-dark-standard.png` |

对照结论：顶部红色横幅（深色 err-bg `#352C31` + err-ink 字 + err-line 边、
`⚠` 符号、右端「知道了」按钮），文案为 HTML 原文“本地数据备份失败：
磁盘空间不足，新收集的题目已保存在本地库中，但这次手动备份没有完成。
请清理磁盘后在「设置」中重新备份。”，位于副标题与焦点卡之间；焦点卡
与下方 4 格正常渲染。因真实应用无“设置页备份失败 → 首页横幅”的通道，
本张用临时展示入口（`lib/showcase_home_error_main.dart`，216px 导航占位
+ 外壳同款内容区 padding，已删除）渲染真实 `HomePage(showBackupError:
true)` 截取；截图后已重新构建正式产物（见 §6）。

### 4.4 回归（`docs/ui-replication/shots/r3/regress/`，2 张）

| 截图 | 结果 |
|---|---|
| `nav-review.png` | 点复习页进入正常：“待解决 3 个错因”（与首页 3 道要复习一致：数学 2 个错因 + 英语 1 个复查错因） |
| `nav-back-home.png` | 点回首页正常，新首页完整渲染（深色标准档） |

## 5. R3 期间修复的两个测试真问题

见 §3（`Row(stretch)` infinite height；亮/深底色测试查找歧义）。
另：首轮 `flutter test` 全量跑了约 9 分钟才出结果（1.5 CPU 的 VM 上
测试编译慢），属环境耗时，非测试挂起。

## 6. 错误态触发方式（本阶段的取舍）

HTML 首页错误态是原型状态切换器演示的场景（手动备份失败）。基线代码里
**没有“设置页备份失败 → 首页横幅”的跨页通道**：设置页 `_backup()` 失败
时无任何状态外传（甚至没有 catch，异常会直接上抛）。R3 只实现横幅本身
（`QmBanner` error 档 + HTML 原文案 + 「知道了」关闭）与触发开关
（`HomePage(showBackupError:)`，默认 false；`app.dart` 未传参，平时不显示），
不擅自发明跨页错误通道。接线方式（例如设置页捕获备份异常后经 app 级状态
通知首页）需负责人定夺，属 R3 未解决问题（§7 第 3 项）。

## 7. 未解决问题 / 待真机复核

| # | 问题 | 说明 |
|---|---|---|
| 1 | Win11 字体/DPI/窗口尺寸待真机复核 | Segoe UI / Microsoft YaHei / Georgia 在 Win11 真机上的实际显示效果、窗口尺寸、DPI、SQLite 原生资源须真机复核；Linux 构建 + Xvfb 点测不能替代 Windows 11 最终验收 |
| 2 | 最近任务 kind 中英文两套写法（已在表现层归一化，未改数据层） | 种子写 `'整理'`、线上代码写 `'organize'` / `'collect'`；基线首页 switch 只认英文，种子行会误判为“复习”。R3 在首页表现层两边都认（§2.2），repository 与种子未动；是否统一数据层写法（种子或写入侧二选一）需负责人定夺 |
| 3 | 错误态无真实触发通道 | 见 §6：设置页备份失败后首页横幅靠 `showBackupError` 开关触发，app 级接线未做，需定夺 |
| 4 | 内容区底部 padding 微小偏差 | HTML `.main` 为 `26px 30px 34px`（底部 34），token 按任务书口径取上下对称 26px；首页先按外壳 token 走，未擅自改为 34（R2 报告 §7 第 8 项的复核结论） |
| 5 | Linux 下学科速览行换行（R2 遗留） | 本机中文字体回退到 Noto Serif CJK（无 Noto Sans CJK），字宽大于微软雅黑，导航“待整理 N · 待复习 M”在 216px 内换行（R2 已知问题，与首页无关，本页未动外壳） |
| 6 | R0 §6-B 业务问题冻结不动 | 报告 `pendingCount` 不按范围过滤、新增学科不同步（`Subject.all` 写死三科）、启动页设置未被消费、通知/备份不完整——R3 一律未动 |
| 7 | HTML 死代码不实现 | 不复活旧翻卡模型、不照搬静态演示数字（待整理实时算）、不实现学科管理死按钮（隐藏/换图标/排序）、不实现错题本学科筛选下拉、不把学科管理文件夹残留做成第五组、设计说明文字不抄入（焦点卡 kicker 已去掉自指说明） |
| 8 | `widgets.dart` 仍有 `Icon` | `showQuestionZoomDialog` 的 zoom_in/out/close 三处 `Icon` 未动，属详情/整理页内部件，R4–R10 逐页处理；`QuestionSlice` 旧色值同 R1-ISSUES 4-3 |
| 9 | 特大字号下首页下半部需滚动 | 1.30 档 1280×720 下四格超出首屏，整页滚动可达、无溢出（与 HTML 整页滚动一致）；小窗口同理 |
| 10 | 底部 4 格在窄窗下变 2 列 / 1 列 | 按 HTML `@media 900/560` 断点实现（`LayoutBuilder`），widget 测试未覆盖窄窗列数（只覆盖 1280×720 三档缩放无溢出）；窄窗形态以截图与 HTML 断点为准，Win11 真机复核时可再确认 |

## 8. 验证用数据库说明

截图与回归用的 Linux 库（`~/.local/share/quiz-master2/quiz-master2.db`）
为 R1 留下的演示库（9 道题，非干净种子态：7 道已加入复习、含 1 条
已解决待复查记录）。验证前已备份到 `/tmp/qm2-db-backup-r3.db`，
空状态截图前另备份到 `/tmp/qm2-r3-empty-orig.db` 并已恢复原库文件；
settings 表恢复为 `themeMode=dark` / `fontSize=standard`（截图前的原值），
`review_joined=1` 的题数核对恢复为 7。角标与首页数字均按该库实时算出，
与 §4 的手工核算一致。
