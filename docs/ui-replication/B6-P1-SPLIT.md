# Batch 6 · P1 确认拆题（SR2-4 / SR2-11 / SR2-25）

执行员 A-split。分支 `ui-replication`，未提交、未推送。

## SR2-4 — 确认拆题丢弃有框页上的独立题内框

### 改了什么

`lib/modules/collect/collect_page.dart`

- `_confirmSplit` 内、每页 1 层框循环之后新增挂接（`:616-633`）：对该页
  `result.standaloneInner[p]` 里的每个独立题内框，按中心点找最近/命中的
  题级框，追加进该题的 `boxesByQuestionId[qid]`，只补 `parentBoxId`。
- 新增静态辅助 `_nearestLayer1Box`（`:746-773`）：中心落在题级框内时
  距离为 0（命中）；否则取中心到框矩形的最短距离（最近）；平局取列表
  里先到的框。落点规则与 `box_editor.dart` `_confirmPendingType`
  一致（中心命中即挂该题）。
- 未框页的独立内框仍走原有保留任务分支（`:674` 附近），不受影响；
  已拆过的页（`alreadySplit`）仍跳过，与 1 层框的处理一致。

### 与规定修法（a）的出入

**有意偏离一点：挂接时不钳制坐标，只补 `parentBoxId`。**

`_confirmPendingType` 对命中框会调 `_clampInner`，但它的钳制区间是
“框内”——独立框中心在框外、整体不与目标框相交时，`x` 会被夹到
`outer.x + outer.w - 0.02`、宽被压到 `0.02`，手画的几何被毁成细条。
确认时挂接的恰恰是“中心在框外”的框，逐字照搬钳制会丢数据。
下游 `layer2BoxToSliceRect`（`lib/widgets/widgets.dart`）本来就把超框
部分夹到 0..1 内（不相交则返回 null、回退示意框），原样保留坐标
在下游是安全的。坐标原样保留 + 只补归属，是保数据优先的选择。

### 测试

`test/collect_page_test.dart`

- `FakeRepo` 新增 `lastBoxesByQuestionId`（`:222`，`confirmSplit`
  内记录，`:238-240`），供断言挂接结果。
- 新组 `SR2-4 有框页独立题内框确认不丢`（`:1248-1314`），用例
  `独立 stem 按中心点挂到最近的题下，确认后仍在该题的框里`：
  草稿第 1 页两道题级框 b1（上）/ b2（下）+ 无父框 stem
  `orphan-stem`（中心 (0.30, 0.49)，落在两框之间，离 b1 0.04、离 b2
  0.06——钉“最近”而非“命中”）；确认后断言 stem 只在 b1 的框里、
  `layer == 2`、`parentBoxId == 'b1'`，且全表只出现一次。
- 该用例覆盖的是 B5 的 P1-6 测试未覆盖的分支（有父框的 inners 已覆盖，
  无父框的 standalone 未覆盖）。

### 证据

`flutter test --concurrency=1 test/collect_page_test.dart`：**45/45 通过**
（含新 SR2-4 用例）。

## SR2-11 — P1-2 确认拆题只测成功路径，未测事务中途失败回滚

### 改了什么

**生产代码未改。**查证：`confirmSplitIntoImpl`
（`lib/data/db_collect.dart:420` 起）已把建题、回填框、建拆分任务、
删原任务、重建保留任务包在同一个 `db.transaction` 里；中途任一步
抛错，sqflite 即回滚整个事务。SR2-11 的缺口只是测试缺口，不是代码
缺口——修法“立触发器断言回滚”不需要改 `db_collect.dart`。

### 测试

`test/b5_p1_256_test.dart`，SR-P1-2 组新增用例（`:606` 起）：

`SR2-11 事务中途写框失败：调用抛错，题/任务/框/原任务全部回滚`

- 与成功用例同款种子（原任务 + 第 1 页草稿框 + 保留任务入参），
  触发器立在种草稿**之后**：
  `BEFORE INSERT ON question_boxes … RAISE(ABORT, …)`——
  命中 `confirmSplitInto` 后半段的框回填写操作。
- 断言 `confirmSplitInto` 抛错，且：题 `import-1` 不存在；
  `collect_tasks` 只有原任务行 `task-orig`（仍是修框中 `boxing`，
  不是回待框选的保留任务）；草稿框 `draft-1` 仍在原任务下、
  `question_id` 仍为空。

### 证据

`flutter test --concurrency=1 test/b5_p1_256_test.dart`：**11/11 通过**
（含新 SR2-11 用例；原 2 个 SR-P1-2 用例未动，全绿）。

## SR2-25 — `_confirmSplit` 成功后 `saveRecentTask` 在 try 外

### 改了什么

`lib/modules/collect/collect_page.dart:704-714`：确认尾部的
`saveRecentTask` 包进 try/catch，失败时 `debugPrint` 记日志后
继续走 `await _load()` 与成功提示。拆题事务本身不受影响
（它在前面的 try 里已提交）。

### 测试

`test/collect_page_test.dart`

- `FakeRepo` 新增 `failSaveRecentTask` 开关（`:225`），为真时
  `saveRecentTask` 抛 `StateError`（`:303`）。
- 新组 `SR2-25 确认拆题后 saveRecentTask 失败不影响成功提示与刷新`
  （`:1316-1345`），用例
  `最近任务写库失败：仍拆题成功，列表刷新到待整理`：
  确认前打开开关，确认后断言拆题已提交（`savedQuestions == 1`）、
  列表已刷新（行上出现「去整理」，「继续修框」「修框」消失——修前
  `_load()` 不执行，列表停在修框中的旧行）、`takeException()` 为空。
  运行日志里可见 `SR2-25：saveRecentTask 失败，已忽略：…`，证明
  catch 分支真实跑到。
- 未直接断言 Snackbar 文案「已生成 1 道题，去整理吧」：默认 4 秒
  自动消失，`tapConfirmAndWait` 的 runAsync + pumpAndSettle 跑完
  时它大概率已消失，断言会 flaky；列表刷新（SR2-25 点名的用户可
  见后果）+ 无未处理异常是等价的硬断言，成功提示走同一条
  `_load()` 之后的代码路径。

### 证据

`flutter test --concurrency=1 test/collect_page_test.dart`：**45/45 通过**
（含新 SR2-25 用例）。

## 验证总览

- `flutter analyze`：**0 问题**。
- 只跑了负责的两个测试文件（串行，未跑全量）：
  - `test/b5_p1_256_test.dart`：11/11。
  - `test/collect_page_test.dart`：45/45。
- 未提交、未推送；未碰 `git reset --hard` / `checkout --` / `clean`。
- 只改了任务指定的文件：
  `lib/modules/collect/collect_page.dart`、
  `test/b5_p1_256_test.dart`、`test/collect_page_test.dart`，
  外加本报告。`lib/data/db_collect.dart` 在范围内但无需改动（见 SR2-11）。

## 遗留问题

1. SR2-4：已拆过的页（`alreadySplit`）上后画的独立内框，确认时
   仍随 `continue` 跳过、静默丢弃——与该页 1 层框的既有处理一致
   （重拆被拦），不在本次修法范围内；若将来允许对已拆页追加内框，
   需另立项。
2. SR2-4：两个题级框到独立内框中心距离完全相等时，取列表先到的框
   （页内顺序即画框/检测顺序），未做额外提示——几何上罕见，可接受。
3. SR2-25：`debugPrint` 只在 debug 模式可见；若将来要求 release
   可追踪，需接正式日志通道，另立项。
