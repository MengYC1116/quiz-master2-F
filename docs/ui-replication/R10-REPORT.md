# R10-REPORT — 学科管理 + 设置重建

- 分支：`ui-replication`（基线 `0c81217242c20fa4438e04db4ebabc92f2c0ddd1`）
- 视觉基准：`~/workspace/your_files/quiz-master2-jiao-hu-yuan-xing/quiz-master2-jiao-hu-yuan-xing.html`，SHA256 `18c8c43485a7831cec22e3d4fff659d7ea39754219b391874f0c5a88f50135e1`（动手前已核对一致）
- 状态：完成并验证通过；未 commit、未 push。

## 0. 本轮起点

任务开始时两页是基线实现（学科管理 `lib/modules/subjects/subjects_page.dart` 829 行、设置 `lib/modules/settings/settings_page.dart` 未计行数，均为 Material 风格），与 HTML 学科管理页（`viewSubjects`）与设置页（`viewSettings`，R0 附录 A）有以下结构偏差：

1. 基线全是 Material 控件（`Icons.*`、AlertDialog、SegmentedButton、Switch），未走 Tokens / UI Kit；
2. 基线缺：章节改名/删除、标签/试卷题数、试卷日期、封面小图预览、删学科长文案确认框、问候语保存按钮、缓存 MB 预览、恢复确认含题数、关于完整文案、加载失败横幅；
3. 基线设置里复习组、数据组、启动与关于组多处只有占位或自创文案，未按 HTML 的简洁直接型（标题 + 一行短说明 + 选项）组织。

直接按 HTML 结构重写两页，必要时补共享 widgets / tokens / 数据查询。本轮环境工具链完好，未重复 R9 的恢复流程。

**D5 先行 grep 结论**：删之前先 grep 确认——Flutter 学科管理里**根本没有**换图标、隐藏学科、学科排序的处理逻辑与残留代码（`Subject` 模型也没有 hidden / icon / order 字段），只有新增、删除、改名；`lib/` 里唯一的“隐藏”相关是错题本已解决题提示（无关）。所以 D5 在本页**无代码可删**（代码注释里已注明）；相关错误提示也不暗示不存在的功能。删后全量测试照常跑（见 §4）。

## 1. 修改文件清单

| 文件 | 改动 |
|---|---|
| `lib/modules/subjects/subjects_page.dart` | 重写（基线 829 行 → 1238 行）：HTML 结构的学科管理页（见 §3）；QmFoldSection ×4 单开默认全折；内联新增输入（学科/标签/试卷/章节）；内联改名行；内联确认框（HTML `.confirmbox` 形态，删学科长文案）；封面块 QmFoldSection form 嵌套，QmCoverMini 样式 + 颜色 swatch（选中 ✓）；知识点树 QmChip 学科页签、章节行（▸/▾ + “· N 个知识点” + 改名/删除）、知识点行、每展开章节底部“＋ 添加知识点”；标签行 `#名 · N 道` + chips 展示；试卷行 `名 · 日期 · N 道题来自这张试卷` + 搜索框（无匹配“没找到这张试卷，换个词试试”）+ 日期按钮（showDatePicker，默认今天）；加载失败 QmBanner 错误横幅可关闭；无 Icon |
| `lib/modules/settings/settings_page.dart` | 重写（→ 1016 行）：HTML 结构的设置页（见 §3）；QmFoldSection ×5 单开默认全折；`_row`（标题 + 一行短说明 + 右侧控件，窄屏换行）；QmSegmented 全部选项（含通知提醒开/关分段，替代 Switch；重做答案“默认藏着/默认显示”）；问候语 QmTextField（maxLength 40）+ “保存问候语”+“恢复默认”，留空保存提示“留空保存不生效”，显示“首页现在显示的是：「…」”；复习组加“加入方式”说明行；缓存清理：递归扫描数据目录按类计数 + 合计 MB，预览“临时文件 N 个、缩略图缓存 M 张，共约 X MB”，确认后清理并显示释放量 + “重新扫描”；恢复：选文件后内联确认框（含备份文件名、备份题数、当前题数）；数据库位置显示完整路径 + “改位置”后显示“新位置已保存：要重启软件才生效”；清空演示数据先查演示题数再内联确认（确认框显示演示题数而非全部题数）；关于 kv 行：版本 quiz-master2 v0.1.0、作者 Meng（个人项目）、更新说明（HTML 长文案）；加载失败横幅（`loadFailed` 参数） |
| `lib/widgets/uikit.dart` | 新增 `QmTextField`（HTML `.toolbar input` 形态：surface 底、line-strong 边、圆角 12、padding 9×13、14px、最小高 40，聚焦 2px accent 边）与 `QmCoverMini`（52×68 封面小图 + `_QmCoverMiniPainter` 自绘纹路，选中 2px accent 边 + accent-soft 底）；文件 R1 建，R10 新增这两组件 |
| `lib/theme/design_tokens.dart` | 新增 `R10Tokens`（学科行、封面小图 52×68、输入框、设置行、kv 行等度量）；文件 R1 建，R10 新增 |
| `lib/data/database.dart` | +35 行：新增 `renameChapter` / `deleteChapter` 查询（只新增查询，不改 Schema；删章节会把题上挂的知识点 id 移除，题还在） |
| `lib/data/repository.dart` | +10 行：对应新增方法 |
| `lib/app.dart` | `_loadSettings` 加 try/catch（失败时用默认设置继续，`_settingsLoadFailed=true`），传给 `SettingsPage(loadFailed:)`；其余 diff 为 R1–R9 累计值。此前加载失败会永远停在 loading spinner（见 §4 真问题 2） |
| `test/subjects_page_test.dart` | 新增 24 个测试（633 行，见 §4） |
| `test/settings_page_test.dart` | 新增 21 个测试（333 行，见 §4） |
| `docs/ui-replication/run-shots-r10.sh` | 新增：probe（导航/段头/点开后坐标校准）/ normal（亮/深 × 标准/大/特大，两页默认态 12 张）/ states（12 张，见 §5） |
| `docs/ui-replication/run-regress-r10.sh` | 新增：首页 → 学科管理 → 展开学科段 → 设置 → 展开外观组 → 回首页（6 张） |
| `docs/ui-replication/shots/r10/html-shots-r10.cjs` | 新增：Playwright 截 HTML 原型学科管理/设置亮/深默认态 + 展开/搜索态，共 10 张（只截 `.win` 应用框，截图前去掉介绍头与 toast；状态切换点 proto-bar 按钮，同 R9 办法） |
| `docs/ui-replication/shots/r10/make-compare-r10.py` | 新增：R9 脚本复制，标签字体 Noto Sans CJK |
| `docs/ui-replication/shots/r10/scan-nav.py` / `scan-heads.py` / `scan-text.py` | 新增：像素扫描定位——导航文字带 / 段头文字带 / 行文字带 |
| `docs/ui-replication/shots/r10/` | 截图 43 张 PNG（24 张 Flutter + 10 张 HTML + 9 张对照图），另 `regress/` 6 张 |

未动：其他七页主体、`lib/models` 的业务语义、`pubspec.lock`、数据库 Schema、`app_icon.ico`；R0 §6-B 业务问题、R9 未解决问题均未顺手改；导航选中项黑/白 pill 是 R2 外壳既有行为（见 §6 第 9 条），R10 未动 `app_shell.dart`。

## 2. git diffstat

R1–R10 均未提交，`git diff --stat` 为相对基线的累计值（15 个已追踪文件，+13450/−5184）。R10 直接相关的部分：

```
lib/modules/subjects/subjects_page.dart | 1475 ++++----（基线 829 行重写 → 1238 行；R1–R9 未动过此文件，全部是 R10）
lib/modules/settings/settings_page.dart | 778 ++++----（重写 → 1016 行；R1–R9 未动过此文件，全部是 R10）
lib/data/database.dart                  | 35 +（只加 renameChapter / deleteChapter 两个查询）
lib/data/repository.dart                | 10 +（对应方法）
lib/app.dart                            | 338 ++----（累计值；R10 只改 _loadSettings try/catch + loadFailed 传参一处，
                                        | 其余为 R1–R9 累计值）
lib/theme/design_tokens.dart            | 未追踪新文件（R1 建；R10 加 R10Tokens 度量块）
lib/widgets/uikit.dart                  | 未追踪新文件（R1 建；R10 加 QmTextField / QmCoverMini）
test/subjects_page_test.dart            | 633 行（未追踪新文件，24 个测试）
test/settings_page_test.dart            | 333 行（未追踪新文件，21 个测试）
docs/ui-replication/                    | 未追踪（R10 新增 run-shots-r10.sh / run-regress-r10.sh / shots/r10）
```

## 3. 结构与 token 来源

- **学科管理页结构（HTML 顺序）**：标题 `学科管理`（24px/800，无 psub——R0 附录 A2 定为设计说明，R8/R9 同款做法只留标题）→ 四段 QmFoldSection（学科 / 知识点树 / 标签 / 试卷），默认全折叠、一次只开一段。学科段：顶部内联新增输入 + “＋ 添加学科”；学科行 = 颜色点 + 名称 + 题数小字在名称下方 + 改名/删除按钮；下方单独可折叠的“错题本封面样式”块（每学科 6 种封面样式、7 种颜色预设，样式与颜色分开存、点即生效）。知识点树：学科页签（一次一棵树，默认数学），章节默认全折叠、点章节名展开，知识点行 = 名称 + 改名/删除，“＋ 添加章节”在顶部、“＋ 添加知识点”在每展开章节底部。标签与试卷：新增控件在段顶部；试卷段顶部有搜索框（按试卷名搜，无匹配显示“没找到这张试卷，换个词试试”）。学科管理里没有文件夹段（文件夹只在错题本目录页管）。
- **封面样式 key 对照**：HTML 样式 key 是 plain / bands / dots / grid / diag / frame，Flutter 存储 key 是 plain / lines / dots / grid / diagonal / double（与错题本 `_CoverPatternPainter` 一致），标签中文相同（纯色折角/横线纹/圆点/方格纹/斜纹/双线框），**不改存储值**。`.cover-mini` 52×68、书脊在左、圆角 4 8 8 4、首字 19px/800 白字；当前封面文案 `当前封面：纯色折角 · 蓝色`。
- **删学科确认框**：内联 `.confirmbox` 形态，长文案含题数与文件夹后果，确认按钮“确认删除这一科和全部 N 道题”；取消不删。删章节确认框含该章知识点数。删标签/试卷确认框为短文案（HTML 同款）。
- **设置页结构（HTML 顺序）**：标题 `设置`（24px/800，无 psub）→ 五组 QmFoldSection（外观 / 复习 / 错题本 / 数据 / 启动与关于），默认全折叠、一次只开一段。外观：主题（跟随系统/浅色/深色）、字号（标准/大/特大）、首页问候语可改（默认“今天也要加油呀”，恢复默认回这句）。复习：复查间隔 3/7/14 天（默认 7）、几次自查算已解决 1/2/3（默认 2）、每次复习解决几个错因 5/10/不限（默认不限）、跳过几次留到下次 1/2（默认 2）、重做答案默认藏着/显示（默认藏着）、复查提醒开关与提醒时间（默认 20:00）、复习列表默认排序（按加入时间默认/按学科）。错题本：默认视图大卡片/紧凑列表（默认大卡片）、默认排序时间新→旧、默认页大小 10（10/20/30/40/50）。数据：备份/恢复（恢复前确认“会覆盖当前题库”）、数据库位置（显示当前路径，改后提示要重启才生效）、缓存清理（清临时文件+缩略图缓存+失败导入残留，清理前预览并确认）、清除演示数据。启动与关于：启动页（首页默认/上次停下的页面）、关于（版本 v0.1.0、作者、更新日志）。设置文案用简洁直接型（标题 + 一行短说明 + 选项），不要长解释。
- **错误态**：两页加载抛错时出 `QmBanner` error 横幅可关闭（学科管理 `加载学科管理数据失败，请重试。`；设置 `设置读取失败，已使用默认设置。`），与 HTML 错误横幅同文案；设置加载失败时用默认设置继续，不再卡 spinner（见 §4 真问题 2）。
- **Token 来源**：全部颜色取自 `DesignTokens`（深色纸面 `#D8DCE2`、深色主色 `#7FA8D0`，D1/D2 已确认）；组件全部用 UI Kit（新增 `QmTextField` / `QmCoverMini` 也只用 Tokens 颜色）；文字符号（▸/▾/✓/＋）不用图标字体；缩放唯一映射 1.00/1.15/1.30，字号只在 app.dart TextScaler 处乘一次，布局尺寸按 `qmScaleOf` 乘一次，不用 Transform.scale。

### 有意偏差（不改 Schema / 不改存储值）

| 项 | HTML / 基线 | Flutter R10 | 原因 |
|---|---|---|---|
| 空章节存不下来 | HTML 可只建章节 | 加章节须同时给第一个知识点（基线行为保留，改为内联表单） | 章节只随知识点存在，建空章节须改 Schema |
| 封面样式存储 key | plain/bands/dots/grid/diag/frame | plain/lines/dots/grid/diagonal/double | 与错题本 `_CoverPatternPainter` 一致，不改已存数据 |
| 设置 psub 列出的不做项 | 首页显示内容开关、封面计数牌开关、导入文件大小、整理台默认排序 | 均不实现 | HTML psub 明示不做，见 R0 附录 A |

## 4. 测试与构建结果

- `flutter analyze`：**No issues found!**
- `flutter test` 全量：**276/276 通过**（基线 231 + R10 新增 45）。
- `flutter build linux --release`：**成功**，产物 `build/linux/x64/release/bundle/quiz_master2`。
- Flutter/Dart 3.47.9 / 3.13.7，路径 `~/workspace/flutter-install/flutter/bin/flutter`。
- R10 新增 45 个测试（`FakeSubjectsRepo` / `FakeSettingsRepo` 全内存覆盖 repository 调用，不碰真实数据库）：四段/五组默认全折 + 一次只开一段 + 点同一段收起；学科增删改名（删学科长文案确认框、取消不删、重名提示）；封面 6 样式 × 7 色点即生效 + 当前封面文案；知识点树页签切换、章节折叠/改名/删除（含知识点数确认）、知识点增删改名、添加章节；标签 # 与题数、增删改名；试卷日期与题数、搜索无匹配、增删改名；设置各分段切换回调值、问候语保存/恢复/留空不生效、缓存预览、清空演示数据确认/取消、加载失败横幅可关闭；亮/深 × 三档无溢出；不用图标字体。

### 本轮发现并已修的两个真问题

1. **问候语输入框被挤得只显示一半文字**：截图时发现 320 宽输入框在标准档只显示“今天也要加油…”。修复：宽度 320→400，改完重新构建并重拍外观组截图确认完整显示（见 §5）。
2. **设置加载失败会永远停在 loading spinner**：`_loadSettings` 无 try/catch，设置读取抛错时页面永不渲染。修复：失败时用默认设置继续，`_settingsLoadFailed=true`，设置页顶部出可关闭的错误横幅（见 §3）。

### 测试调试中修的三个测试侧问题（非产品问题）

1. `FakeSubjectsRepo` 字段名 `tags` / `exams` 与父类方法冲突，改名 `tagsList` / `examsList`；
2. 确认框标题与章节名用 `Text.rich`，`find.text` 匹配不到，改用 `find.textContaining`；
3. Fake 的 `renameTag` 未同步更新题目的标签导致计数为 0，已按真实数据库行为补齐；
4. 另：改名输入框要用 `find.byType(TextField).last`（工具栏输入框在前）；确认按钮在首屏外时先 `ensureVisible` 再点；无溢出循环的 helper 也要先 `ensureVisible` 再点，否则点落空、测试空洞通过。

## 5. 截图对照（Xvfb 1280×720，真实库 9 题、7 条错因记录）

截图目录 `docs/ui-replication/shots/r10/`（43 张 PNG：24 张 Flutter + 10 张 HTML + 9 张对照图），另 `regress/` 6 张。HTML 原型是静态演示数据（DEMO_TODAY 2026-11-11），与真实库数字/题名不同——对照只看结构/样式/文案，不逐数比对。真实库：数学/英语/政治各 3 道题；试卷 3 张（均 2026-11-13 前后）；标签题数与试卷题数与库一致。

| 截图 | 对照结论 |
|---|---|
| `subjects-light/dark-standard.png`、`subjects-light/dark-large.png`、`subjects-light/dark-extraLarge.png` | ✓ 学科管理默认态：四段全折叠，亮/深 × 三档无溢出；与 HTML 默认态结构一致。差异：特大档左导航学科速览数字换两行、政治行底部裁切（R6/R9 同款既有行为，非 R10 引入）；特大档设置按钮在首屏外（见坐标校准）。 |
| `settings-light/dark-standard.png`、`settings-light/dark-large.png`、`settings-light/dark-extraLarge.png` | ✓ 设置默认态：五组全折叠，亮/深 × 三档无溢出；与 HTML 默认态结构一致。差异同上（导航）。 |
| `subjects-open-light-standard.png` | ✓ 学科段展开：内联新增输入 + 三科行（颜色点 + 名称 + “3 道题”小字 + 改名/删除）+ 封面块折叠头；与 HTML 学科段展开结构一致。 |
| `subjects-cover-light-standard.png` / `subjects-cover-dark-standard.png` | ✓ 封面块展开：数学 6 小图 + 标签（纯色折角/横线纹/圆点/方格纹/斜纹/双线框）+ 颜色行（蓝/绿/红/紫/橙/黄/灰，✓ 在当前色）+ 当前封面文案正确（数学 纯色折角 · 蓝色；英语 纯色折角 · 绿色）；亮/深均正确。 |
| `subjects-kp-open-light-standard.png` | ✓ 知识点树展开一章：页签 ✓数学/英语/政治、＋ 添加章节、章节行（▸/▾ + “· N 个知识点” + 改名/删除）、知识点行 + 每展开章节底部“＋ 添加知识点”；与 HTML 知识点树展开结构一致。 |
| `subjects-delconfirm-light-standard.png` | ✓ 删学科确认框：红色长文案（含 3 道题与文件夹后果）+ “确认删除这一科和全部 3 道题”；与 HTML 删学科确认框文案一致。 |
| `subjects-exams-search-light-standard.png` | ✓ 试卷段展开：搜索框已输入“不存在的卷子”、新增行含日期按钮 2026-11-13、“没找到这张试卷，换个词试试”、无试卷行；与 HTML 试卷搜索无匹配结构一致。Unicode 码点输入已验证可用（见坐标校准）。 |
| `settings-appearance-light-standard.png` | ✓ 外观组展开：主题（跟随系统/浅色✓/深色）、字号（标准✓/大/特大）、问候语输入框完整显示“今天也要加油呀”+ 保存问候语/恢复默认 + “首页现在显示的是：「今天也要加油呀」”；与 HTML 外观组一致。问候语截断问题已修（见 §4 真问题 1），本图为修复后重拍。 |
| `settings-review-light-standard.png` / `settings-review-scrolled-light-standard.png` | ✓ 复习组展开：加入方式说明行 + 各分段选中态正确（7 天 / 2 次 / 不限 / 2 次 / 默认藏着 / 提醒开、提醒时间 20:00、按加入时间）；滚动后下半部分（重做答案、提醒、排序）同样正确；与 HTML 复习组一致。 |
| `settings-wrongbook-light-standard.png` | ✓ 错题本组展开：默认视图（大卡片✓/紧凑列表）、默认排序（时间新→旧✓）、默认页大小（10✓/20/30/40/50）；与 HTML 错题本组一致。 |
| `settings-data-light-standard.png` | ✓ 数据组展开：备份/恢复/数据库位置（完整路径 `/home/hatch/.local/share/quiz-master2/quiz-master2.db`，改位置按钮）/ 清理缓存（本机无可清理缓存，显示“现在没有可清理的缓存。”，按钮置灰）/ 清空演示数据；与 HTML 数据组一致。缓存 MB 预览数字由 widget 测试覆盖（本机扫描结果为 0，见 §6 第 8 条）。 |
| `settings-startup-light-standard.png` | ✓ 启动与关于组展开：启动页（首页✓/上次停下的页面）、关于 kv 行（版本 quiz-master2 v0.1.0、作者 Meng（个人项目）、更新说明长文案）；与 HTML 启动与关于组一致。 |
| `regress/regress-home.png`、`regress-subjects.png`、`regress-subjects-open.png`、`regress-settings.png`、`regress-settings-open.png`、`regress-back-home.png` | ✓ 首页 → 学科管理 → 展开学科段 → 设置 → 展开外观组 → 回首页链路正常；本回归不改库。 |
| `html-subjects-light/dark.png`、`html-subjects-open-light.png`、`html-subjects-cover-light.png`、`html-subjects-kp-light.png`、`html-subjects-exams-search-light.png`、`html-settings-light/dark.png`、`html-settings-appearance-light.png`、`html-settings-review-light.png` | ✓ Playwright 截的 HTML 原型两页（只截 `.win` 应用框，无介绍头、无 toast）。 |
| `compare-subjects-default-light/dark.png`、`compare-subjects-cover.png`、`compare-subjects-kp-open.png`、`compare-subjects-exams-search.png`、`compare-settings-default-light/dark.png`、`compare-settings-appearance.png`、`compare-settings-review.png` | ✓ HTML（上）/ Flutter（下）并排对照 9 张。结构/样式/文案一致；剩余差异见本表各行与 §6。 |

### 截图脚本的坐标校准（教训，写给后续轮次）

- **像素扫描定位法**（R7 定下，R8–R10 再验证）：不要凭缩放后的截图目测。本轮实测中心（标准档 1280×720）：导航“学科管理”Y 353 / 大 389 / 特大 443；导航“设置”Y 667（标准档）。大/特大档设置按钮在首屏外：导航区滚 6 次（大）/ 8 次（特大）后设置 Y 为 678/674（已验证可滚可点）。
- **默认态段头/组头**（标准档）：学科管理 学科 279 / 知识点树 348 / 标签 415 / 试卷 483；设置 外观 245 / 复习 313 / 错题本 382 / 数据 449 / 启动与关于 518。
- **点开后页面会上滚**（焦点滚动，R1 共享 `_QmPressable` Focus 的既有行为，设置页同样出现，非 R10 引入）：学科段点开后标题 225→67，学科段头 121，输入框 169，数学行 229（删除按钮 x=1205）、英语 291、政治 353，封面头 422；知识点树点开后第一章行 356；试卷段点开后搜索框 411、新增行 456、试卷行 505/555/605（未展开搜索时）。
- **试卷搜索框 Y 的一次标错**：初版脚本把搜索框标成 Y 221——那其实是点开后移到该处的知识点树段头，点它会切到知识点树（第一版 `subjects-exams-search` 截图拍到的就是知识点树展开，已废弃）。修正为 411 后重跑 states 验证正确，脚本注释已写明教训。
- **章节行只响应文字区**：第一章行点文字区 x=350 可点，行内空白 x=700 点不到——GestureDetector 默认只响应子控件区域，与 HTML 行内按钮形态一致，不改。
- **中文输入**：`xdotool type` 打不出中文（Invalid multi-byte sequence），改用 Unicode 码点逐字敲入（不 U4E0D 存 U5B58 在 U5728 的 U7684 卷 U5377 子 U5B50），已验证可用。
- **states 脚本 `set -euo pipefail`**：此前因 `xdotool type` 中文失败中断过一次，已改成 Unicode 码点输入并重跑成功；重跑后对照图须同步用新截图重新生成（`compare-subjects-exams-search.png` 曾用旧截图生成，已重生成）。
- **Playwright 环境**：与 R8/R9 相同（浏览器在 `~/workspace/.playwright-browsers`，`PLAYWRIGHT_BROWSERS_PATH` 须显式设；模块在 npx 缓存）。

## 6. 未解决问题

1. **Win11 字体/DPI/窗口尺寸待真机复核，Linux 结果不替代 Win11 验收。** 尤其 Linux 回退字体（Noto Sans/Serif CJK）与 Win11 的微软雅黑/等线行高度量不同，各处 12.5–15px 小字与标签需真机确认无裁切；1280×720 以外窗口尺寸也须真机复核；Windows Release 构建须在 Meng 的 Win11 机器上验证。
2. **点段头后页面上滚约 136–158px**（焦点滚动，R1 共享组件既有行为，各折叠页都有，非 R10 引入；截图坐标已按点开后实测值处理）。
3. **章节行只响应文字区**（x=350 可点，行内空白 x=700 点不到），与 HTML 行内按钮形态一致，不改。
4. **大/特大档左导航学科速览数字换行、政治行底部裁切**（R6/R9 同款既有行为，非 R10 引入）；大/特大档设置按钮在首屏外，须滚动导航才能点到。
5. **导航选中项呈纯黑（亮色）/纯白（深色）**（R2 外壳既有行为，R9 §6 第 9 条，R10 未动 `app_shell.dart`）。
6. **空章节存不下来**：加章节须同时给第一个知识点（不改 Schema 的有意偏差，见 §3）。
7. **设置错误态真实窗口截图不可触发**：`loadFailed` 只在设置读取失败时出现，真实应用内无故障注入入口；widget 测试覆盖，同 R9 §6 第 8 条。学科管理加载失败横幅同理（widget 测试覆盖，无真实窗口截图）。
8. **缓存清理 MB 预览数字无真实窗口截图**：本机数据目录下无临时文件/缩略图缓存/失败导入残留，真实窗口只显示“现在没有可清理的缓存。”；带 MB 数字的预览流程由 widget 测试覆盖。
9. **R0 §6-B 其余业务问题未动**：学科管理新增学科不同步到首页/导航速览（`Subject.all` 写死三科）；设置“启动页”未被消费；通知提醒无调度实现；备份导出不含 4 张表。
10. **分页 / 真实 YOLO / 真实图片切片 / 系统拖放仍未验证**（R10 范围外既有项）。
11. **封面小图纹路在小尺寸下较淡**（与 HTML 同款细微纹路一致）。

## 7. 验收后状态

- 真实库已恢复：设置 `themeMode=dark`、`fontSize=standard`（截图前后核对一致），备份已删除；截图过程除主题/字号切换外未改库内容（9 道题、7 条错因记录原状）。
- 未 commit、未 push；分支 `ui-replication`，基线 `0c81217242c20fa4438e04db4ebabc92f2c0ddd1`。
- R10 交付物：两页重写 + `QmTextField` / `QmCoverMini` + `R10Tokens` + `renameChapter` / `deleteChapter` + 设置加载失败处理；45 个新增测试；截图 43 张 + 回归 6 张；本报告。
