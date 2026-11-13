# S8 QmChip / SubjectLabel 只认三科 id 修复

- 裁决：Meng 2026-11-13 15:24，QmChip 与 SubjectLabel 只认三科 id 必须修。
- 状态：完成。`flutter analyze` 0 问题；`flutter test` 全量 377/377；
  Linux Release 构建成功；Linux 真机亮/深截图验证通过。
- 改动文件：`lib/widgets/uikit.dart`、`lib/widgets/widgets.dart`、
  `lib/modules/collect/collect_page.dart`、
  `lib/modules/review/review_page.dart`、
  `lib/modules/report/report_page.dart`、
  `lib/modules/wrongbook/wrongbook_page.dart`、
  `lib/modules/subjects/subjects_page.dart`、
  `test/s8_chip_label_test.dart`（新增）、
  `docs/ui-replication/run-shots-s8chip.sh`（新增）。
- 边界：`Subject.byId` 未改（仍是多处回退的兜底）；未改 Schema、
  业务规则/口径、未增删功能、未改已定决策、未升级依赖、未改
  `pubspec.lock`；未碰 YOLO；未 commit、未 push。

## 1. 两个组件的签名变化

修法参照 S8A2 的 stored 思路：组件保持纯展示，不查库，存色/存名
由调用方从库学科对象传入；未传时保持现有行为（预设三科走主题
固定色）。

### QmChip（`lib/widgets/uikit.dart`）

新增可选参数 `Color? storedColor`，两处选中填充都传给
`DesignTokens.subjectColor(subjectId, brightness, storedColor)`
（交互态与 `displayOnly` 展示态）。`subjectColor` 本就按 S8A2
规则忽略预设三科的 stored、只对新学科用存色，所以预设三科
即使传了存色也仍走主题固定色。

### SubjectLabel 与 subjectLabelColor（`lib/widgets/widgets.dart`）

- `subjectLabelColor(context, subjectId, [Color? stored])`：新参数
  `stored` 非空且 id 不是预设三科时，亮/深都直接返回存色
  （与 `subjectColor` 的 stored 规则一致）；不传则旧行为不变
  （亮色学科本色、深色冷雾色 switch）。
- `SubjectLabel` 新增可选参数 `Subject? subject`：传了就用它的
  名与存色（`subjectLabelColor(context, subjectId, subject?.color)`），
  新学科不再显示成“数学”+数学色；不传则走 `Subject.byId` 回退
  （预设三科旧行为不变）。

## 2. 覆盖的调用点

四页各加一个 `_subjectOf(id)` helper（在 `_subjects` 里找，找
不到才回退 `Subject.byId`，只发生在数据不一致时；各页 `_subjects`
B2 之后已有，本次没动 `_load()`）。

### 2.1 QmChip / SubjectLabel 的调用点

| 位置 | 改前 | 改后 |
|---|---|---|
| `subjects_page.dart:838` 知识点树学科页签 `QmChip`（全仓唯一传 `subjectId` 的 QmChip 调用点，`s` 即库学科） | `subjectId: s.id`，新学科选中填充落到数学色 | 加 `storedColor: s.color` |
| `collect_page.dart:729` 任务行 `SubjectLabel` | 只传 `subjectId`，化学任务行显示“数学”+数学色 | 加 `subject: subject`（该行已有的 `_taskRow` 局部变量，见 2.2） |
| `collect_page.dart:699` 筛选 chips | 没传 `subjectId`，不用动 | 未动 |

### 2.2 B2 补充报告 §3 表，逐项修完

| 表内位置 | 内容 | 改后 |
|---|---|---|
| `review_page.dart:437` | 会话范围标签 `${Subject.byId(_subjectFilter!).name}这一科` | `${_subjectOf(_subjectFilter!).name}这一科` |
| `review_page.dart:634, 673` | 会话内 `_SessionChange` 的 `subjectName`（自查总结行） | `_subjectOf(q.subjectId).name` |
| `review_page.dart:787` | “上次解决到一半”恢复条学科名 | `_subjectOf(q.subjectId).name` |
| `review_page.dart:952, 972` | 复习列表组行：名 + `subjectInk` 未传存色 | `final subject = _subjectOf(g.subjectId)`，名取 `subject.name`，`subjectInk(..., subject.color)` |
| `review_page.dart:1177, 1202` | 已治愈分组行：名 + `subjectInk` 未传存色 | 同上 |
| `review_page.dart:1285` | 未加入复习列表 `数学「题名」` | `_subjectOf(q.subjectId).name` |
| `review_page.dart:1317` | 会话题目学科名 | `_subjectOf(q.subjectId).name` |
| `report_page.dart:302` | “接下来练什么”句 `Subject.byId(...).name` | `_subjectOf(causeTop.first.subjectId).name` |
| `collect_page.dart:288` | 修框编辑器对话框 `subjectName` | `_subjectOf(task.subjectId).name` |
| `collect_page.dart:710` | 任务行 `final subject = Subject.byId(...)`（任务备注与 SubjectLabel 共用） | `_subjectOf(task.subjectId)` |
| `wrongbook_page.dart:280` | `_searchHaystack` 学科名（搜“化学”以前匹配不到，因为 haystack 里是“数学”） | `_subjectOf(q.subjectId).name` |
| `wrongbook_page.dart:974` | `_openBookFrame`：`subject.coverColor` 决定打开的书外框色，新学科以前取数学的蓝封面 | `_subjectOf(subjectId)`，用库里的 `coverColor` |
| `wrongbook_page.dart:1447` | 目录页标题 `subject.name` | `_subjectOf(subjectId)` |
| `wrongbook_page.dart:1660` | 删除文件夹确认文案里的学科名 | `_subjectOf(f.subjectId)` |
| `wrongbook_page.dart:2103` | 列表页标题 `${subject.name} · 错题本` | `_subjectOf(_subjectId!)` |

`report_page.dart:628` 弱点行与 `wrongbook_page.dart:3020` 紧凑行
已是 B2 补充修好的 `_subjects` + 存色写法，本次核对无改动。

## 3. 同类回退未修（请 Meng 定是否后续同步）

不在 B2 补充报告 §3 表内，本次按任务边界未动（组件是纯展示，
这些位置拿不到库学科对象，要改需给各页/组件加传参或加 `_load`
读库，改动面超出本次裁决）：

| 位置 | 现状 | 可见症状 |
|---|---|---|
| `wrongbook_page.dart:1234-1236` | 书架封面英文词 switch：`english → ENGLISH`、`politics → POLITICS`、`_ → MATHEMATICS` | 化学书封面英文词仍是 `MATHEMATICS`（本次截图已复现，见 §5） |
| `lib/widgets/widgets.dart:176, 353` | `QuestionSlice` / `CompactSliceThumb` 图片加载失败兜底：`Subject.byId(question.subjectId)` 取图标 + 名 + `subjectLabelColor` | 新学科题图加载失败时显示“数学”+数学色图标（组件只拿到 `Question`，无库学科可传） |
| `home_page.dart:195, 437` | 首页最近题目名 `${Subject.byId(...).name}` | 新学科的题在首页会显示成数学 |
| `organize_page.dart:584, 1119, 1529, 1973, 2017, 2368` | 整理工作台题目学科名 / 队列备注 / 删除确认文案 | 同上 |
| `detail/question_detail_page.dart:591, 822, 1062, 1135, 1252` | 题目详情学科名 / 知识点新建提示里的学科名 | 同上 |

`Subject.byId` 本身未改，仍是数学兜底；四页新增的 `_subjectOf`
找不到时也回退到它（只发生在数据不一致时）。

## 4. 测试清单与结果

### 4.1 `flutter analyze`

0 问题（新测试文件初版有 3 个 import 警告，已清掉）。

### 4.2 `flutter test`（全量 377/377）

新增 `test/s8_chip_label_test.dart`，11 个测试，全部通过
（全量由 B2 补充结束时的 338 → 本次 377，含其间 B3/B4 新增）：

| 测试 | 覆盖 | 断言 |
|---|---|---|
| QmChip 新学科选中填充（亮/深） | §1 | 填充含存色紫 `0xFF7C5CFC`，不含数学色 |
| QmChip 新学科展示态选中填充 | §1 | 填充含存色紫 |
| QmChip 预设三科行为不变 | §1 | 传了存色也仍走数学主题固定色，不含紫 |
| QmChip 不传存色旧行为不变 | §1 | 新学科仍按 id 查表落到数学色 |
| SubjectLabel 新学科（亮/深） | §1 | 显示“化学”，圆点与文字颜色 = 存色紫 |
| SubjectLabel 预设三科行为不变 | §1 | 不传 subject 仍显示数学+数学色 |
| subjectLabelColor 传存色亮/深 | §1 | 亮/深都直接用存色 |
| 收集任务行 | §2.2 | 化学任务显示“化学”，圆点紫 |
| 复习组行 | §2.2 | 化学组名颜色 = 存色紫 |
| 报告“接下来练什么” | §2.2 | 出现“先解决化学的概念不清”，无“先解决数学的” |
| 错题本目录标题 | §2.2 | “化学 · 错题本”出现一次，无“数学 · 错题本” |

## 5. Linux 真机验证（1280×720，Xvfb，亮/深）

验证脚本 `docs/ui-replication/run-shots-s8chip.sh`
（`probe` 模式只截探针图量坐标；默认完整流程；改库前整库备份，
trap 恢复；杀应用 `pkill -x quiz_master2`）。学科管理页 QmChip
用一次性脚本 `/tmp/s8chip-subjects.sh` 补拍（脚本本身不留存，
坐标已记在本报告 §5 末尾）。

临时改库（拍完已恢复）：加化学（紫 `0xFF7C5CFC`，轮换表第 4 位）
+ 2 道题（`q-chem-1` 已整理已加入复习 + pending 错因“概念不清”；
`q-chem-2` 已整理、同错因、未加入复习）+ 1 条化学收集任务
（`t-chem-1`，排队中）。两道化学题同错因，便于报告句取最弱。

截图目录 `docs/ui-replication/shots/s8chip/`（21 张）：

| 截图 | 内容 | 结果 |
|---|---|---|
| `probe-collect-dark.png` | 收集中心探针 | ✅ 任务行“● 化学 化学讲义.pdf · 第1页 · 第1题”，紫点紫字 |
| `probe-review-dark.png` | 复习页探针 | ✅ 组行“化学 概念不清”紫名；未加入列表“化学「氧化还原配平」” |
| `probe-shelf-dark.png` | 书架探针 | ✅ 化学书灰封面，`2 道题 / 1 要复习 / 0 待复查`；封面英文词仍是 `MATHEMATICS`——见 §3 未修项 |
| `probe-report-dark.png` | 报告页探针 | ✅ “接下来练什么 先解决化学的概念不清。”；弱点行 `1 化学 · 概念不清 2 道题` 紫名 |
| `collect-task-dark/light.png` | 收集任务行 | ✅ 亮/深均为紫色“化学” |
| `review-menu-dark/light.png` | 复习学科筛选菜单 | ✅ 含化学 |
| `review-filtered-dark/light.png` | 选化学后 | ✅ 筛选框显示“化学”，列表只剩 1 组（化学 概念不清，紫名）；未加入列表化学在首位 |
| `wrongbook-dir-dark/light.png` | 化学书目录 | ✅ 标题“化学 · 错题本”，`全部题目 2 道题`，外框为化学的灰封面色 |
| `report-next-dark/light.png` | 报告顶部 | ✅ “接下来练什么 先解决化学的概念不清。”；弱点行紫名 |
| `subjects-kp-chem-dark/light.png` | 学科管理 → 知识点树 → 点化学 chip | ✅ “✓ 化学”选中填充为紫色，与数学蓝明显不同；亮/深一致 |
| `subjects-top-{dark,light}.png`、`subjects-kp-{dark,light}.png`、`probe-home-dark.png` | 过程图（导航与展开） | 仅作坐标记录 |

学科管理页坐标（1280×720）：导航“学科管理”行 (100, 353)；
“知识点树”区块头 (700, 162)；化学 chip (515, 208)。

## 6. 演示库恢复

验证后恢复原状（脚本 trap 自动执行，每次运行均核对）：
学科 3、题目 9、收集任务 0、`themeMode=dark`、`startupPage=home`、
`lastRoute=/home`，备份文件已删除；应用已杀
（`pkill -x quiz_master2`），无残留 Xvfb 进程。

## 7. 改动文件（未 commit、未 push）

- `lib/widgets/uikit.dart`：QmChip 加 `storedColor` 参数，两处
  选中填充传给 `subjectColor`。
- `lib/widgets/widgets.dart`：`subjectLabelColor` 加 `[Color? stored]`
  参数；`SubjectLabel` 加 `Subject? subject` 参数。
- `lib/modules/collect/collect_page.dart`：`_subjectOf` helper；
  修框对话框名、任务行学科对象、任务行 SubjectLabel 传 subject。
- `lib/modules/review/review_page.dart`：`_subjectOf` helper；8 处
  学科名 + 2 处 `subjectInk` 传存色（范围标签、总结行、恢复条、
  组行、已治愈行、未加入列表、会话题名）。
- `lib/modules/report/report_page.dart`：`_subjectOf` helper；
  “接下来练什么”句。
- `lib/modules/wrongbook/wrongbook_page.dart`：`_subjectOf` helper；
  搜索 haystack、打开书外框色、目录标题、删文件夹文案、列表标题。
- `lib/modules/subjects/subjects_page.dart`：知识点树 QmChip 传
  `storedColor: s.color`。
- `test/s8_chip_label_test.dart`（新增，11 个测试）。
- `docs/ui-replication/run-shots-s8chip.sh`（新增）、
  `docs/ui-replication/shots/s8chip/*.png`（21 张）。
- 本报告 `docs/ui-replication/S8-CHIP-LABEL-REPORT.md`。

注：`git diff` 里这 7 个 lib 文件的行数变化大于本次改动，因为
工作区此前已有他人进行中的改动（B4 等）；本次只动了上表所列
位置，未碰其他人的进行中代码。

## 8. 未做的事

- 未碰 YOLO；未碰 B4 及以后。
- §3 的同类回退清单（书架封面英文词、图片失败兜底、首页/整理台/
  详情页学科名）未修，等 Meng 定（见 §3）。
- Win11 真机复核仍待 Meng：亮/深、字体/DPI 下的表现以 Win11 为准；
  化学书封面英文词 `MATHEMATICS` 在 Win11 上同样可见，是否改由
  Meng 定。
