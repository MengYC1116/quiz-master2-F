# B8-6：整理工作台右侧表单改手风琴（一次只展开一个）

- 批次：第 8 批第 6 项（Meng Win11 真机验收 2026-11-15 14:46，第 6 项）
- 分支：`ui-replication`；工作树 `~/workspace/quiz-master2-UI`
- 状态：完成；`flutter analyze` 0 问题；目标测试通过（见下）

## 改了什么

整理工作台右侧表单四区（文件夹 / 来源 / 分类补充 / 答案·解析·笔记）
改成手风琴：一次只能展开一个，点开一个就收起其他；点已展开的区收起它
（允许四区全收）。左栏「修框切片」是独立折叠段，不参与手风琴。

- `lib/modules/organize/organize_page.dart`
  - 新增文件级枚举 `_RightSection { folder, source, classify, answer }`。
  - 新增 `_toggleRightSection(section)`：点未展开的区→只开它、其余全收起；
    点已展开的区→收起它。四个 `QmFoldSection` 的 `onToggle` 全改走它。
  - 新增 `_openRightSectionOnly(section)`：只开指定区。两处原先直写
    `_folderOpen = true` 的地方改走它，保持手风琴不变形：
    - `_confirmCurrent` 文件夹必填未选时拦下并跳回文件夹区；
    - `_missingLine`「待补充」里「文件夹（归类）」的跳转。
  - 默认态不变：文件夹展开，其余三区折叠（本来就只文件夹开着，与手风琴一致）。
- `lib/widgets/uikit.dart`：`QmFoldSection` 的注释改对——以前写“整理表单 /
  详情三段 / 收集说明用每段独立的布尔值，可多段同开”，现整理表单四区
  自 B8-6 起是手风琴（组件本身仍不做互斥，互斥是调用方的选择）。

未碰：`box_editor.dart`、`collect_page.dart`（第 3/4/5 项工人的文件）；
详情页三段、收集说明、设置五组、学科管理四组的开合口径一律不动。

## 口径翻转记录（必读）

- 第二批 Bug 4（见 `docs/ui-replication/B2-WIN11BUG-ORGANIZE.md` 与
  `docs/ui-replication/B2-WIN11BUG-SUMMARY.md`）：当时 Meng 要求整理表单
  各区“能同时打开多个”，截图 image-79 里“文件夹（归类）”与“来源（可选）”
  同时显示“收起”即为该口径的证据；`test/b2_win11bug_organize_test.dart`
  的 Bug 4 组当时按多开锁了行为（同时开三区 + 文件夹都保持展开，
  默认文件夹展开、其余折叠）。
- 本次（2026-11-15 Win11 验收第 6 项）：Meng 明确改回一次只能展开一个。
  按这次的执行，旧决定作废。
- 随翻转同步改动的旧物：
  - `test/b2_win11bug_organize_test.dart`：文件头 Bug 4 注释 + Bug 4 组
    已按新手风琴口径重写（组名改为「表单四区手风琴（B8-6 翻转：一次只开
    一个）」，断言改为点开一区、其他区收起；再点已开区收起它；四区全收时
    只剩左栏修框切片一个「收起」）。
  - `docs/ui-replication/B3-SUMMARY.md` 第 43 行与
    `docs/ui-replication/SELF-REVIEW-COLLECT.md` 第 165 行曾记载“整理表单
    各区独立多开”是当时的正确记录，现已过时（不改历史文档，在此注明）。

## 回归用例

- 新增 `test/b8_6_accordion_test.dart`（FakeRepo，不碰真实数据库，无文件 IO），4 个：
  1. 默认只文件夹展开，其余三区收起；左栏修框切片独立展开；
  2. 点开来源收起文件夹；再点分类补充收起来源；
  3. 点已展开的区收起它：四区全收，只剩左栏切片一个「收起」；
  4. 确认校验跳回文件夹：先打开来源区，再点「确认整理，去下一道」
     （题未选文件夹）→ 提示「先选文件夹」+ 只开文件夹区。
- 更新 `test/b2_win11bug_organize_test.dart` Bug 4 组（见上），1 个。

## 验证

- `flutter analyze`：No issues found。
- `flutter test --concurrency=1 test/b8_6_accordion_test.dart`：4/4 通过。
- `flutter test --concurrency=1 test/b2_win11bug_organize_test.dart`：
  2/2 通过（Bug 3 + 翻转后的 Bug 4）。
- `flutter test --concurrency=1 test/organize_page_test.dart`：37/37 通过。
- 全量与 Linux Release 构建：见 `docs/ui-replication/B8-1-SWEEP.md`
  末尾（与第 1 项扫尾同一轮验证）。
