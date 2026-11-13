# S8 B2 补充：§2 的 8 处未同步点全部修完

- 裁决：Meng 2026-11-13 17:48 追加，B2 报告 §2 的 8 处未同步点全部修。
- 状态：完成。`flutter analyze` 0 问题；`flutter test` 全量 338/338；
  Linux Release 构建成功；Linux 真机亮/深截图验证通过。
- 改动文件：`lib/data/repository.dart`、`lib/modules/review/review_page.dart`、
  `lib/modules/report/report_page.dart`、`lib/modules/collect/collect_page.dart`、
  `lib/modules/wrongbook/wrongbook_page.dart`、
  `test/s8b2_subject_sync_supplement_test.dart`（新增）、
  `test/review_page_test.dart`、`test/report_page_test.dart`、
  `test/collect_page_test.dart`、`test/wrongbook_page_test.dart`
  （四个 FakeRepo 加 `subjects` 覆盖，默认仍是预设三科）、
  `docs/ui-replication/run-shots-s8b2-supplement.sh`（新增）。
- 边界：只做 B2 报告 §2 的 8 处；`QmChip` / `SubjectLabel`
  （`lib/widgets/uikit.dart`）未碰（另有专人）；B3 及以后未碰；
  未改 Schema、业务规则/口径（除本次裁决的 8 处）、未增删功能、
  未改已定决策、未升级依赖、未改 `pubspec.lock`。

## 1. 改了什么（8 处，统一改成读库 subjects）

各页新增 `_subjects` 状态（初值 `Subject.all`，`_load()` 里
`repo.subjects()` 读库，空库回退预设三科；与 B2 首页/导航同一做法）。
颜色一律走 B2 给 `subjectInk` 加的 `stored` 参数（预设三科传了存色
也仍走主题固定色；新学科用存色）。

| # | 位置（当前行号） | 改前 | 改后 |
|---|---|---|---|
| 1 | `review_page.dart:220` 附近，复习按学科排序的顺序表 | `Subject.all` 建索引，新学科无索引位（回退 99） | 用 `_load()` 里读库的 `subjectList` 建索引 |
| 2 | `review_page.dart:885` 附近，学科筛选下拉 | 遍历 `Subject.all`，新学科没有筛选项 | 遍历 `_subjects` |
| 3 | `report_page.dart:163` 附近，`_subjectOrder` | `Subject.all.indexWhere`，新学科定位 -1 → 99 | `_subjects.indexWhere` |
| 4 | `report_page.dart:444-450`，按学科分布 | 遍历 `Subject.all`，新学科不出现 | 遍历 `_subjects` |
| 5 | `report_page.dart:622-623`，弱点行 | `subjectInk(group.subjectId, brightness)` 未传存色，新学科落到数学色；名也走 `Subject.byId` 回退到数学 | 在 `_subjects` 里找学科，名与色都取它，`subjectInk(..., subject.color)` |
| 6 | `repository.dart:202`，`subjectCounts()`（错题本封面三数） | 按 `Subject.all` 初始化键，新学科缺键 → 封面三数显示 0 | 按 `await subjects()`（库 subjects 表）初始化键；口径一字未动 |
| 7 | `collect_page.dart:577`，导入学科下拉 | `items: Subject.all`，**新学科选不到、无法导入**（最关键） | 遍历 `_subjects` |
| 8 | `wrongbook_page.dart:3020`，紧凑行/归档行 `_prowMetaLine` | `Subject.byId` 未知 id 回退到数学名 + `subjectInk(..., Brightness.light)` 未传存色 | 在 `_subjects`（错题本页本来就有，B2 时已读库）里找学科，`subjectInk(..., subject.color)`；亮度仍取 `Brightness.light`（纸面浅色档，既有行为，未动） |

### 附带改动（只为让第 6 处可单测，行为不变）

`subjectCounts()` 原先直读 `_db.allCauseRecords()`，FakeRepo 覆盖不到；
改为走仓库已有的 `causeRecords()`（同义委托）。口径、返回值不变。

## 2. 测试清单与结果

### 2.1 `flutter analyze`

0 问题。

### 2.2 `flutter test`（全量 338/338）

新增 `test/s8b2_subject_sync_supplement_test.dart`，7 个测试，全部通过
（全量由 B2 结束时的 323 → B3 的 331 → 本次 338）：

| 测试 | 覆盖 | 断言 |
|---|---|---|
| subjectCounts：新学科有计数键 | #6 | `counts` 含 `subject-chem` 键，值为 `(1, 0, 0)`；数学已解决 1 道；英语键存在为 `(0, 0, 0)` |
| 复习按学科排序：两个新学科按入库顺序排 | #1 | 化学（第 4 位）与历史（第 5 位）加入时间故意倒过来（历史更早），按学科排序时化学组仍在历史组上面；旧代码下两科同落 99 位、按加入时间排，历史会在上 |
| 复习学科筛选下拉：新学科出现且能选中过滤 | #2 | 下拉菜单含 `subject-chem`，选中后只剩化学组，数学题消失 |
| 学习报告按学科分布：新学科出现且计数正确 | #4 | `化学 · 1 道错题` 出现一次 |
| 学习报告弱点行：新学科名与颜色走存色 | #3+#5 | 化学 2 道同错因进 Top 5 首行；`化学`  span 颜色 = 存色紫 `0xFF7C5CFC`，≠ 亮色数学 ink（颜色只断言等于存色、不等于数学色） |
| 收集中心导入学科下拉：新学科出现且能选中 | #7 | 菜单含 `化学`，选中后下拉按钮显示 `化学`，`请选择学科` 消失 |
| 错题本紧凑行：新学科名与颜色走存色 | #8 | 切紧凑列表后明细行 `化学` span 颜色 = 存色紫，≠ 亮色数学 ink |

四个 FakeRepo（review / report / collect / wrongbook）各加
`subjects` 覆盖能力，默认仍是预设三科，老测试不受影响。

注：`pickMenuItem` 助手在点下拉菜单项时会打一条 hit-test 警告
（tap 的落点未命中菜单项本身），既有 `review_page_test.dart`
跑全量时同样出现 8 次，是该助手的老问题，本次未动；筛选断言
本身验证了选中确实生效。

### 2.3 Linux 真机验证（1280×720，Xvfb，亮/深）

验证脚本 `docs/ui-replication/run-shots-s8b2-supplement.sh`
（`probe` 模式只截探针图量坐标；默认完整流程；改库前整库备份，
trap 恢复；杀应用 `pkill -x quiz_master2`）。深色一遍是交互验证
（与脚本同一坐标），亮色一遍走脚本。

临时改库（拍完已恢复）：加化学（紫 `0xFF7C5CFC`，轮换表第 4 位）
+ 2 道题（`q-chem-1` 已整理已加入复习 + 1 条 pending 错因 →
要复习 1；`q-chem-2` 未整理 → 待整理 1）。与 B2 验证用的同一批数据。

截图目录 `docs/ui-replication/shots/s8b2-supplement/`：

| 截图 | 内容 | 结果 |
|---|---|---|
| `collect-menu-dark/light.png` | 收集中心导入学科下拉菜单 | ✅ 数学/英语/政治/**化学** 四项齐全 |
| `collect-selected-dark/light.png` | 点化学后 | ✅ 下拉按钮显示 `化学`，可导入状态就绪 |
| `review-menu-dark/light.png` | 复习学科筛选下拉菜单 | ✅ 全部/数学/英语/政治/**化学** 五项齐全 |
| `review-filtered-dark/light.png` | 选化学后 | ✅ 筛选框显示 `化学`，列表只剩 1 组（化学平衡移动）；组行学科名显示 `数学`——见 §3 遗留点 |
| `wrongbook-dir-dark/light.png` | 点化学书进目录 | 目录标题显示 `数学 · 错题本`——见 §3 遗留点；`全部题目 1 道题` 正确 |
| `wrongbook-compact-dark/light.png` | 全部题目 → 紧凑列表 | ✅ 明细行 `化学 · 错误类型：概念不清 · 标签：—`，`化学` 为紫色（亮/深一致） |
| `report-dist-dark/light.png` | 学习报告（滚到分布区） | ✅ 弱点行 `4 化学 · 概念不清` 紫名；分布行 `化学 · 2 道错题`（本周内两道化学题） |
| `probe-*.png` | 探针图（首页/收集/复习/书架/报告） | 书架化学书：灰封面，`1 道题 / 1 要复习 / 0 待复查`——第 6 处封面三数已同步（旧代码会显示 0 要复习）；封面英文词显示 `MATHEMATICS`——见 §3 遗留点 |

## 3. 本次未动的同类回退（请 Meng 定是否后续同步）

B2 §2 清单之外的 `Subject.byId` / `subjectInk` 未传存色点，
本次 8 项之外仍在，截图里已可见（新学科的题在这些位置仍显示
成“数学”或数学色）。未动的原因：不在本次裁决的 8 项清单内。

| 位置（当前行号） | 现状 | 截图里的可见症状 |
|---|---|---|
| `review_page.dart:434` | 会话范围标签 `${Subject.byId(_subjectFilter!).name}这一科` | 化学筛选进会话后范围文案会写“数学这一科” |
| `review_page.dart:630, 667` | 会话内题目 `subjectName` | — |
| `review_page.dart:781` | 会话题目学科名 | — |
| `review_page.dart:946, 966` | 复习列表组行：名 `Subject.byId` + `subjectInk` 未传存色 | `review-filtered-*.png`：化学组行显示 `数学 概念不清` |
| `review_page.dart:1171, 1196` | 会话总结行：名 + `subjectInk` 未传存色 | — |
| `review_page.dart:1279` | 未加入复习列表 `数学「题名」` | `probe-review-dark.png`：`数学「氧化还原配平」`（应为化学） |
| `review_page.dart:1311` | 某处题目学科名 | — |
| `report_page.dart:302` | `接下来练什么` 用 `Subject.byId(...).name` | 化学成最弱时句子会写“先解决数学的……” |
| `collect_page.dart:288, 710` | 收集任务行学科名 `Subject.byId` | 化学任务行会显示数学 |
| `wrongbook_page.dart:280` | 大卡片某处学科名 | — |
| `wrongbook_page.dart:974, 1447, 2103` | 目录/列表标题 `Subject.byId(subjectId)` | `wrongbook-dir-*.png` / `wrongbook-compact-*.png`：标题 `数学 · 错题本`（应为化学） |
| `wrongbook_page.dart:1660` | 文件夹行学科名 | — |
| `wrongbook_page.dart:1234-1236` | 书架封面英文词 switch：`english → ENGLISH`、`politics → POLITICS`、`_ → MATHEMATICS` | `probe-shelf-dark.png`：化学书封面英文词是 `MATHEMATICS` |
| `lib/widgets/uikit.dart:532, 556` | QmChip / SubjectLabel 未传存色 | 另有专人修，本次未碰 |

## 4. B2 报告里的另外两个现象（本次不动，仍记在这里）

1. **6 科时导航速览 5 行把“设置”按钮顶出 720px 首屏**（B2 报告 §5
   第 1 条）：导航列本身可滚动，按钮能滚出来，不是丢失；本次 4 科
   验证未复现，仍待 Meng 定是否压缩行高或改布局。
2. **第 6 科轮换色绕回数学蓝**（B2 报告 §5 第 3 条）：学科管理页
   `_newSubjectColors` 只有 5 个色，第 6 科 `orElse` 取首位，与数学
   新蓝 `0xFF2E7CF6` 完全相同，只能靠科名区分；本次未动。

## 5. 演示库恢复

验证后恢复原状（脚本 trap 自动执行，两次运行均核对）：
学科 3、题目 9、`themeMode=dark`、`startupPage=home`、
`lastRoute=/home`，备份文件已删除；应用已杀
（`pkill -x quiz_master2`），无残留 Xvfb 进程。

## 6. 改动文件（未 commit、未 push）

- `lib/data/repository.dart`：`subjectCounts()` 键改按库 subjects 表；
  记录改走 `causeRecords()`（行为不变）。
- `lib/modules/review/review_page.dart`：`_subjects` 状态 + 排序顺序表
  与筛选下拉读库。
- `lib/modules/report/report_page.dart`：`_subjects` 状态 + 弱点定位、
  分布、弱点行读库/传存色。
- `lib/modules/collect/collect_page.dart`：`_subjects` 状态 + 导入学科
  下拉读库。
- `lib/modules/wrongbook/wrongbook_page.dart`：`_prowMetaLine` 在
  `_subjects` 里找学科并传存色。
- `test/s8b2_subject_sync_supplement_test.dart`（新增，7 个测试）。
- `test/review_page_test.dart`、`test/report_page_test.dart`、
  `test/collect_page_test.dart`、`test/wrongbook_page_test.dart`：
  FakeRepo 加 `subjects` 覆盖。
- `docs/ui-replication/run-shots-s8b2-supplement.sh`（新增）、
  `docs/ui-replication/shots/s8b2-supplement/*.png`（19 张，
  含 5 张探针图）。
- 本报告 `docs/ui-replication/S8B2-SUBJECT-SYNC-SUPPLEMENT-REPORT.md`。

## 7. 未做的事

- 未碰 B4 及以后；未碰 `QmChip` / `SubjectLabel`（另有专人）。
- 复习按学科排序的 Linux 真机截图未单独做：排序逻辑是纯函数式
  的，已由 widget 测试覆盖（化学/历史两科加入时间倒置仍按入库
  顺序排）；Linux 只验证了筛选下拉与过滤后列表。
- Win11 真机复核仍待 Meng：亮/深、字体/DPI 下的表现以 Win11 为准。
