# R2 报告 — 应用外壳与导航重建

> 阶段：R2（应用外壳与导航）。只改 `lib/app.dart` 及必要的外壳相关文件
> （`lib/widgets/app_shell.dart` 新增、`lib/theme/design_tokens.dart`、
> `lib/widgets/uikit.dart`、`lib/widgets/widgets.dart`）；
> 九个页面主体文件一个字未动，数据库 / Repository / 业务口径未动，
> 未升级依赖、未改 `pubspec.lock`、未 commit、未 push。
> 视觉基准 SHA256 已核对一致：交互原型
> `18c8c43485a7831cec22e3d4fff659d7ea39754219b391874f0c5a88f50135e1`。

## 1. 修改文件清单

| 文件 | 改动 |
|---|---|
| `lib/app.dart`（改） | 474 → 272 行：`_buildNav` 整体换成 `AppNavBar`；内容区包 `--surface` 底 + `ScaledTokens.contentPadding`；删掉 8 项导航（含设置）与全部 `Icon`/`Icons`；删掉底部“设计演示数据”文案；路由分发、`_refreshBadges`、`_go/_goReview/_goWrongbookFiltered/_openDetail`、主题接线原样保留 |
| `lib/widgets/app_shell.dart`（新增，577 行） | 纯展示左导航 `AppNavBar`：主列表 7 项 + 底部 side-foot（学科速览 + 设置按钮）；角标、选中态、折叠、亮/深、三档缩放全部 token 化；不读数据库、不碰业务口径 |
| `lib/theme/design_tokens.dart`（改） | R1-UIKIT §7 第 1 项定夺执行：HTML 实读字号/间距收入 token（见 §2）；`AppPalette` 新增 `badgeSelectedBg/Fg`（选中态角标底色/字色） |
| `lib/widgets/uikit.dart`（改） | `_Html` 集中表删除，全部引用改为 `DesignTokens`；`QmGlyphs` 新增 `chevronLeft` 与导航文字符号（`⌂ ⇪ ✎ ▤ ↺ ▦ ☰ ⚙`）；`QmChip` 新增 `displayOnly` 展示态（见 §5） |
| `lib/widgets/widgets.dart`（改） | `EmptyState` / `InfoChip` / `DashedDivider` 收口为 UI Kit 转发（签名不变，九页调用处不动，见 §5） |
| `test/app_shell_test.dart`（新增，18 个） | 外壳导航 widget 测试：7 项、设置在底部、折叠、角标、亮/深、三档缩放、小窗口不溢出 |
| `test/widgets_forward_test.dart`（新增，6 个） | 三个旧组件的转发测试 |
| `docs/ui-replication/run-shots-r2.sh`（新增） | 6 张外壳截图脚本（亮/深 × 标准/大/特大，改 settings 表后恢复） |
| `docs/ui-replication/run-regress-r2.sh`（新增） | 九页点通回归脚本（xdotool 点导航 + 折叠） |
| `docs/ui-replication/shots/r2/`（新增） | 6 张首页外壳截图 + `regress/` 9 张回归截图 |

`git diff --stat`（工作树含 R1 未提交改动；以下仅 R2 直接改动的已跟踪文件）：

```text
lib/app.dart             | 296 ++++++++---------------------------------------
lib/widgets/widgets.dart |  91 +++++++--------
```

`lib/theme/design_tokens.dart` 与 `lib/widgets/uikit.dart` 在 R1 是新增未跟踪
文件，R2 的改动不体现在 `git diff` 里（见 §2、§5）。`lib/models/models.dart`、
`lib/theme/app_theme.dart` 的未提交改动是 R1 的，R2 未动。
`windows/runner/resources/app_icon.ico` 未动（SHA-256 仍为
`c098d3fc85cacff98b8e69811b48e9f0d852fcee278132d794411d978869cbf8`）。

## 2. R1-UIKIT.md §7 第 1 项定夺：HTML 实读字号/间距收入 DesignTokens

**定夺：收入。** 理由：这些值是原型 CSS 的实读值、不是随手写的魔法数，
且多组件共用（按钮 / 芯片 / 药丸 / 横幅 / 折叠头 / 导航）；收进 token 后
`uikit.dart` 的私有 `_Html` 集中表已删除，改为直接引用 `DesignTokens`，
不再有两处事实来源。字号仍只写基准值，由 app.dart 的 `MediaQuery
TextScaler` 全局缩放一次，组件内不乘（D4 不变）。

收入项（全部见 `DesignTokens` 的“HTML 实读字号 / 间距”与“左导航实读度量”
两节，逐项注明 HTML 来源）：按钮字 14 / 小按钮 13 / 大按钮 17.5、芯片 13、
分段 14、横幅 14、药丸 12、空状态标题 17、折叠头 16.5 / 14.5、大按钮圆角 14
（=(12+16)/2）、单行控件行高 1.2、按钮最小高 40 / 34 / 56、各内边距
（9×20、6×14、16×20、5×14、4×12、7×18、12×16、4×14、9 横向、52×30）、
导航品牌 17 / 副标题 11.5、导航项 14.5、角标 11.5（最小宽 22、高 20）、
导航项内边距 10×12、外壳内边距 16×12、速览标题 12、速览行 13.5
（内边距 7×10、圆点 10）。另在 `AppPalette` 新增选中态角标 token
`badgeSelectedBg/Fg`：亮色 `#FFFFFF/#175CD3`，深色 `#D5DBE4/#33465A`
（HTML `.side nav button[aria-current="page"] .bdg`）。

## 3. 结构说明

### 3.1 导航（`AppNavBar`，纯展示组件）

- 主列表 **7 项**：首页、收集中心、整理工作台、错题本、复习、学习报告、
  学科管理。**设置不在主列表里**，在左下角 side-foot（QmButton 小按钮，
  `.btn.small` 形态）；在设置页时该按钮呈主按钮选中态。折叠态下设置只剩
  齿轮符号按钮（Tooltip“设置”）。
- 品牌行：`quiz-master2` 17px/800 + 副标题“个人智能错题本”11.5px muted；
  折叠/展开箭头保留（`‹` / `›` 文字符号），折叠 = 仅图标 64px，
  沿用已确认的折叠行为。HTML 原型无折叠导航、无导航图标——图标位用
  `QmGlyphs` 文字符号保留（`⌂ ⇪ ✎ ▤ ↺ ▦ ☰ ⚙`），全库无 `Icon`
  （`lib/app.dart` 的 `Icon`/`Icons` 已清零；测试断言覆盖）。
- 选中态：accent 底 + accent-ink 字（亮 `#2E7CF6`/白字，深 `#7FA8D0`/
  `#131A24` 深字），700 字；未选中 ink-2 字、600 字，悬停 surface 底。
- 角标：收集灰档（`.bdg.grey`：surface-3 底 + ink-2 字）、整理 accent 档；
  选中项的角标用 `badgeSelectedBg/Fg` token；为 0 时不显示。
- 学科速览：标题“学科速览”12px/700 muted（字距 .08em），每科一行
  （圆点 10px 学科色 + 科名 + `待整理 N · 待复习 M`，13.5px，悬停 surface
  底）。**行只展示、不跳转**（HTML 原型 `subjrow` 只有悬停态，无跳转行为）。
- 导航列可滚动：空间够时 side-foot 贴底（Spacer），不够时
  （小窗口 / 大字号）整列滚动、不溢出黄条（SingleChildScrollView +
  ConstrainedBox(minHeight) + IntrinsicHeight，见 §6 的实测修复）。

### 3.2 角标与速览口径（沿用现有口径，未改 repository）

- 收集角标 = `CollectPage.countPendingBox`（待框选 + 修框中任务数）
  + `pendingOrganizeCount`（未整理题数）；整理角标 =
  `pendingOrganizeCount`；刷新机制 `badgeVersion` 监听 + `_refreshBadges`
  原样保留。注：HTML 的收集角标是待框选（fix）+ 待整理任务（ready），
  基线代码是待框选/修框中任务 + 未整理题数——R2 按任务书“沿用 repository
  现有口径”保留基线公式，未改口径。
- 学科速览待复习与首页焦点卡同一口径（`homeRevCounts`：手动加入复习且
  已整理且至少一个错因未解决或已到复查时间，**数题不数错因**）；
  待整理按学科实时算（`pendingOrganizeBySubject`），不照搬 HTML
  写死的演示数字“待整理 3”。

### 3.3 内容区与路由

- 内容区：`Expanded` 内 `Container`，底色 `--surface`，内边距
  `ScaledTokens.contentPadding`（26/30，按 1.00/1.15/1.30 缩放）。
  **过渡期总缩进偏大**：九页主体仍带各自的旧内边距（24–28px），
  与外壳 26/30 叠加后总缩进约 50/58px；R3–R10 逐页接 UI Kit 时去掉
  页内边距后落到准确的 26/30（见 §7）。HTML `.main` 底部是 34px，
  token 仍按任务书口径取上下对称 26px，记为一处微小偏差。
- 路由分发（9 路由手动分发）、详情页 `Navigator.push`、角标刷新机制、
  原生标题栏（D1，不复刻 HTML 模拟标题栏）、主题跟随系统默认且可手动
  亮/深（沿用现有设置接线），全部原样保留。
- 基线底部“设计演示数据”文案已删除（HTML 原型里没有）。

## 4. Token 来源

颜色、圆角、间距、字号全部取自 `DesignTokens`（R1 已核对的 HTML
`:root` / 深色 `@media` 值）与 §2 新增的 HTML 实读度量；`AppNavBar`
与 `app.dart` 外壳不再写死色值/尺寸。导航宽 216/64、内容区 padding
26/30、全部布局尺寸按 `ScaledTokens` 缩放；字号只写基准值，由
`MediaQuery TextScaler` 全局缩放一次，不重复缩放，不用
`Transform.scale`。

## 5. widgets.dart 收口（只改 widgets.dart，九页调用处不动）

- `EmptyState` → `QmEmptyState`：旧 `message` 作新组件 `title`
  （17px/700）；旧形态是无边框简化版，新形态是 HTML 忠实形态
  （1.5px 虚线圆角框 + 小伙伴 + 标题 + CTA），各页空状态外观随之统一。
  回归截图证实：收集中心空状态已是虚线框形态。
- `InfoChip` → `QmChip(displayOnly: true)`：为此给 `QmChip` 加了
  `displayOnly` 展示态——`QmChip` 无 `onTap` 时会被 `_QmPressable`
  当成 Disabled（opacity .45），不能直接转发。`color` 非空时只有一处
  调用（复习页已解决错因的绿 `0xFF1F9D66`），用同一几何尺寸、该色
  10% 透明底渲染，保留“已解决为绿”的含义（`QmChip` 没有 color 参数）。
  转发后芯片带 line-strong 细边、13px 字（旧 12px 无边），见复习页截图。
- `DashedDivider` → `QmRowLine`：纸线色 → `paper` 档，其余 → `line` 档。
  注意：`QmRowLine` 按当前主题取 token 色；错题本列表分隔线旧调用处
  写死浅色纸线值，在深色下会按 `line` 档取深色线色（R3 错题本页改
  为直接传 kind 时消除）。
- 未动：`showQuestionZoomDialog` 里的 `Icon`（zoom_in/out/close）仍在，
  属详情/整理页内部件，R3–R10 逐页接 UI Kit 时处理；
  `QuestionSlice` / `_SliceFigurePainter` 的旧色值（R1-ISSUES 4-3）仍在，
  待真实图片切片替换时清理。

## 6. 测试与构建结果

| 检查 | 结果 |
|---|---|
| `flutter analyze` | **No issues found!** |
| `flutter test` | **62/62 通过**（R1 的 38 个 + R2 新增 24 个：`test/app_shell_test.dart` 18 个 + `test/widgets_forward_test.dart` 6 个） |
| `flutter build linux --release` | **成功**：`✓ Built build/linux/x64/release/bundle/quiz_master2` |

新增测试覆盖：7 项导航各一次、设置只出现一次（底部）、折叠态文字消失
只剩 Tooltip、点导航/设置回调路由、展开 216px / 折叠 64px、三档缩放
导航宽与内容区 padding token、选中态亮/深色值、角标灰档/accent 档/
选中态 `badgeSelected` token/为 0 不显示、设置页底部按钮选中态、
学科速览每科数字与缺省 0、亮/深导航底色 surface-2、全库无 `Icon`、
R2 收入 token 的 HTML 实读值、三个旧组件的转发行为。

**测试中发现并修复的两个真问题**（均已修完、测试覆盖）：
1. **导航列纵向溢出**：默认测试视口 800×600 下，大字号（1.15）溢出
   34px、特大（1.30）溢出 119px；1280×720 真实窗口下特大档内容高
   约 703px、也已逼近窗口高。修复：导航列改为可滚动结构（§3.1），
   空间够时 foot 贴底，不够时滚动；新增“小窗口 + 特大字号不溢出”测试。
2. **学科速览行横向溢出**：`待整理 N · 待复习 M` 在 216px 导航内放不下
   （Row 不换行，标准字号溢出 52px）。修复：计数文本包 `Flexible`
   （真实字体下一行放得下，fallback 字体偏宽时自动换行）。

## 7. 截图对照（Xvfb 1280×720，Release 产物）

截图脚本：`docs/ui-replication/run-shots-r2.sh`（亮/深 × 标准/大/特大，
改 settings 表后自动恢复原值 dark/standard）、
`docs/ui-replication/run-regress-r2.sh`（xdotool 点导航 + 折叠）。
本机无 headless 浏览器，无法直接渲染 HTML 原型做像素并排；对照方式为
逐条 HTML CSS 规则 → Flutter 截图实测值（见下表）。

### 7.1 首页外壳 6 张（`docs/ui-replication/shots/r2/`）

| 截图 | 路径 |
|---|---|
| 亮色标准 | `docs/ui-replication/shots/r2/home-light-standard.png` |
| 亮色大 | `docs/ui-replication/shots/r2/home-light-large.png` |
| 亮色特大 | `docs/ui-replication/shots/r2/home-light-extraLarge.png` |
| 深色标准 | `docs/ui-replication/shots/r2/home-dark-standard.png` |
| 深色大 | `docs/ui-replication/shots/r2/home-dark-large.png` |
| 深色特大 | `docs/ui-replication/shots/r2/home-dark-extraLarge.png` |

### 7.2 对照结论（HTML 规则 → 截图实测）

| HTML 规则 | 实测 |
|---|---|
| `.side` 底色 surface-2、宽 216px | 亮 `#FDF3D8` 暖纸底、深 `#21262E` 冷灰底；标准档导航宽 216px（测试断言），大 248px、特大 281px |
| 主列表 7 项，设置在左下角 | 7 项齐全，设置只在底部（亮色 plain 小按钮、深色同；设置页时呈主按钮选中态） |
| 选中态 accent 底 + accent-ink 字 | 亮 `#2E7CF6` 白字、深 `#7FA8D0` 深字（深色 accent 本身偏浅，视觉上接近浅蓝白，与 token 值一致） |
| 角标：收集灰档、整理 accent 档 | 收集 `4` 灰底、整理 `4` 蓝底；选中项角标亮 `#FFFFFF/#175CD3`、深 `#D5DBE4/#33465A` |
| 角标数字实时算（非演示数） | 当前库实测：收集 4（0 个待框选任务 + 4 道未整理题）、整理 4；焦点卡“要复习 3 道”与速览合计一致 |
| 学科速览：数学 待整理 1 · 待复习 2、英语 1 · 1、政治 2 · 0 | 与 `pendingOrganizeBySubject` / `homeRevCounts` 的库内实算一致（数学已整理 2/待整理 1、待复习 2；英语待复习 1 为已解决到复查时间的题；政治待复习 0，因其已加入的题均未整理） |
| 内容区 padding 26/30、三档缩放 | token 已接（测试断言 1.00/1.15/1.30）；但九页自带内边距叠加，过渡期总缩进偏大（§3.3）；三档下导航、字号、按钮同步放大，无截断、无溢出黄条 |
| 折叠 64px 纯图标 | 回归截图证实：64px、仅文字符号、角标以小 pill 挂在图标右上角、底部设置齿轮选中态 |
| 亮/深两套主题 | 6 张截图亮/深底色、文字色、角标色均与 token 一致 |

### 7.3 回归（`docs/ui-replication/shots/r2/regress/`，9 张）

| 页 | 结果 |
|---|---|
| 收集中心 `page-collect.png` | 进入正常；选中态角标为选中态配色；空状态已是 QmEmptyState 虚线框形态 |
| 整理工作台 `page-organize.png` | 进入正常；队列“还剩 4 道”，第 1/4 道 |
| 错题本 `page-wrongbook.png` | 进入正常；三科书架正常渲染 |
| 复习 `page-review.png` | 进入正常；“待解决 3 个错因”，InfoChip 已是带细边的展示态 |
| 学习报告 `page-report.png` | 进入正常；核心数与弱点列表正常 |
| 学科管理 `page-subjects.png` | 进入正常；四段折叠正常 |
| 设置 `page-settings.png` | 进入正常；底部设置按钮呈选中态 |
| 折叠 `nav-collapsed.png` | 64px 纯图标 + 角标 + 底部设置齿轮选中态 |
| 展开回首页 `nav-expanded-home.png` | 展开后回首页正常，角标仍为 4/4 |

注：回归脚本第一版折叠点击坐标误写为 (215, 40)（落在内容区），
当时 `nav-collapsed.png` 与设置页截图相同；已修正为品牌行箭头中心
(188, 32)、展开箭头 (32, 32)，重跑后折叠/展开均证实。

## 8. 未解决问题 / 待真机复核

| # | 问题 | 说明 |
|---|---|---|
| 1 | Win11 字体/DPI/窗口尺寸待真机复核 | Segoe UI / Microsoft YaHei / Georgia 在 Win11 真机上的实际显示效果、窗口尺寸、DPI、SQLite 原生资源须真机复核；Linux 构建 + Xvfb 点测不能替代 Windows 11 最终验收 |
| 2 | Linux 下学科速览行换行 | 本机中文字体回退到 Noto Serif CJK（无 Noto Sans CJK），字宽大于微软雅黑的 1em，`待整理 N · 待复习 M` 在 216px 内放不下而换行（Flexible 兜底，无溢出）。Win11 用 Microsoft YaHei 时按字宽估算应为一行，须真机确认；如真机也换行，再议是否缩短文案或改两行式 |
| 3 | 内容区双份内边距（过渡期） | 外壳 26/30 已接，但九页自带 24–28px 内边距未去，总缩进偏大；R3–R10 逐页去掉页内边距后落到准确的 26/30 |
| 4 | 特大字号下导航 foot 需滚动才可见 | 1.30 档内容高约 703px，1280×720 下设置按钮在首屏底部边缘外，需滚导航才可见（可滚动结构已保证可达、无溢出）；小窗口同理 |
| 5 | R0 §6-B 业务问题冻结不动 | 报告 `pendingCount` 不按范围过滤、新增学科不同步（`Subject.all` 写死三科）、启动页设置未被消费、通知/备份不完整——R2 一律未动 |
| 6 | HTML 死代码不实现 | 不复活旧翻卡模型、不照搬静态演示数字、不实现学科管理死按钮（隐藏/换图标/排序）、不实现错题本学科筛选下拉、不把学科管理文件夹残留做成第五组、设计说明文字不抄入 |
| 7 | `widgets.dart` 仍有 `Icon` | `showQuestionZoomDialog` 的 zoom_in/out/close 三处 `Icon` 未动，属详情/整理页内部件，R3–R10 逐页处理；`QuestionSlice` 旧色值同 R1-ISSUES 4-3 |
| 8 | 内容区底部 padding 微小偏差 | HTML `.main` 为 `26px 30px 34px`（底部 34），token 按任务书口径取上下对称 26px；R3–R10 去页内边距时一并复核是否改为 34 |
| 9 | 速览行只展示、不跳转 | 与 HTML 原型一致；如负责人希望点科名进错题本，需另行定夺（属行为新增，R2 未做） |

## 9. 验证用数据库说明

截图与回归用的 Linux 库（`~/.local/share/quiz-master2/quiz-master2.db`）
为 R1 留下的演示库（9 道题，非干净种子态：部分题已加入复习、含 1 条
已解决待复查记录）。验证前已备份到 `/tmp/qm2-db-backup.db`，
验证后已恢复原库；settings 表恢复为 `themeMode=dark` /
`fontSize=standard`（截图前的原值）。角标与速览数字均按该库实时算出，
与 §7.2 的手工核算一致。
