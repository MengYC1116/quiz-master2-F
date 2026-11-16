# B11-10 整理队列为空时的今日小结（最小版）

## 结论

整理队列为空且库里有题时（空状态「都整理完了，去复习吧」），空状态卡
下方新增一行：`今天整理了 N 道、待复习 M 道`。只这一行，不加本周累计
与连续天数。从未有题的空状态（「没有待整理的题目」）不显示该行。

## 改了什么文件

| 文件 | 改动 |
|---|---|
| `lib/data/database.dart` | 新增 settings 键 `organizedTodayKey = 'organizedToday'`；新增静态透传 `loadOrganizedTodayFrom` / `bumpOrganizedTodayInto` |
| `lib/data/db_settings.dart` | 新增口径纯函数 `organizedTodayDateText` / `organizedTodayCountFromValue` / `bumpOrganizedTodayValue`；新增句柄版读写 `loadOrganizedTodayFromImpl` / `bumpOrganizedTodayIntoImpl`；`AppDatabaseSettings` 扩展新增 `organizedTodayCount({DateTime? now})` |
| `lib/data/db_questions.dart` | `upsertQuestionIntoImpl`：写之前读旧行判断未整理→已整理跃迁，写成功后跃迁才 +1 |
| `lib/data/repository.dart` | 新增 `organizedTodayCount({DateTime? now})`（一行透传） |
| `lib/modules/organize/organize_page.dart` | 新增 `_organizedToday` / `_toReviewCount`；`_refresh` 只在队列已空且库里有题时读两个数；`_emptyPage` 队列已空分支在空状态卡下加小结行 |
| `test/organize_page_test.dart` | `FakeOrganizeRepo` 新增 `organizedTodayValue` / `dueTodayValue` 字段与 `organizedTodayCount` / `dueToday` 覆盖（默认 0 / 空） |
| `test/b11_11_empty_states_test.dart` | `_B11OrganizeRepo` 新增 `organizedTodayCount` / `dueToday` 覆盖（返回 0 / 空；该文件会走到队列已空，不覆盖会调真实库） |
| `test/b11_10_today_summary_test.dart`（新） | 10 个测试（见下） |

未改动：Schema（不加列、不升版本——见决策 D2）、`Question` 模型、
`db_codec`、备份/恢复、其他 worker 的主文件。

## 行为

- 触发条件：`_refresh` 里 `pending.isEmpty && all.isNotEmpty` 时读数；
  队列非空时不读（省一次全表 + 记录查询），从未有题时不显示该行。
- 显示：空状态卡下方 12px 处一行居中 muted 文字，
  `今天整理了 $_organizedToday 道、待复习 $_toReviewCount 道`，
  13.5px。亮/深主题共用 `palette.muted`，不新增颜色。
- 计数时点：`_confirmCurrent`（单道确认）与队列弹窗 `_batchConfirm`
  （批量确认）都走 `repo.save → upsertQuestion`，跃迁在
  `upsertQuestionIntoImpl` 里统一计，两条路都不会漏；确认最后一道后
  的 `_refresh` 读到的数已包含刚确认的这道。

## 数字口径（写死）

- **N1 = 今天已整理的题数**：settings 表键 `organizedToday`，值
  `yyyy-MM-dd|N`（本地日期，月、日零补齐）。N 是当天内经整理确认
  （含队列批量确认）由未整理变为已整理的题数。
  - 只计跃迁：旧行存在且 `is_organized = 0` → 新行 `= 1` 时 +1。
  - 不计：新行直接以已整理入库（种子/恢复路径）；已整理题的重复保存；
    草稿保存（未整理）不计。
  - 日期不是当天时读出来是 0；值损坏（不是 `日期|整数`）按 0 读，下一次
    +1 时按当天重写，不弹错。
  - **最小版已知局限**：已整理后又被删的题不回减（计数是事件计数，不
    是按题反查）；跨天不保留昨天的数；恢复旧备份后计数跟备份内的
    settings 行走。如需按题反查，见决策 D2。
- **N2 = 待复习题数**：直接复用 `repo.dueToday().length`——与首页焦点卡
  / 复习角标同一套 live 计算（`homeRevCounts` 各科之和即
  `dueToday().length`，见 `app_shell.dart` B9-3 注释）。口径：手动加入
  复习、已整理、至少一个错因未解决（待解决/解决中）或到了复查时间；
  数题不数错因；已归档的题不算。不是新口径，没有第二套数字。

## 测试结果

新文件 `test/b11_10_today_summary_test.dart`，10/10 通过（串行，
`flutter test --concurrency=1`，默认 /tmp，内存库，不碰真实库）：

- 口径纯函数 3 个：无行/空串/坏值读 0；当天读 N、昨天按 0 读；
  +1 从 1 起、当天累加、跨天重计、坏值重计。
- 真库跃迁计数 3 个（`AppDatabase.openForTest()` 内存库）：
  未整理→已整理 +1、重复保存不计、第二道再 +1；新行直接已整理入库
  不计；跨天读 0、指定 now 可读昨天的数（经仓库 `organizedTodayCount`
  读同一数）。
- Widget 4 个：队列已空显示「今天整理了 3 道、待复习 2 道」（假实现
  供数）；队列非空不显示；从未有题不显示；确认最后一道后空状态出现
  该行（假实现返回 0/空，显示 0 道、0 道；真实计数由真库用例覆盖）。

相关既有测试复核（串行）：`test/organize_page_test.dart`、
`test/b11_11_empty_states_test.dart`、`test/b2_win11bug_organize_test.dart`、
`test/b8_6_accordion_test.dart`、`test/b8_1_subject_sweep_test.dart`、
`test/b5_p2_collect_test.dart` 共 92/92 通过（第一次跑时
`b5_p2_collect_test.dart` 的 SR2-62 闪失败 1 个；单跑与重跑整批均
通过，是该用例本身的时间敏感随机段断言抖动，与本项无关）。
upsert 路径相关文件另逐个跑过（多文件同批跑时曾因多 worker 并发跑测试
挤占共享编译缓存、14 分钟不出 tester 而卡住，已杀掉重跑单个文件，均
通过）：`b9_1_collect_done_test.dart` 7/7、`b5_p2_data_test.dart` 61/61、
`p1_schema_backup_test.dart` 21/21、`b5_p1_1_subject_counts_test.dart` 5/5。

`flutter analyze`（所改文件）：0 问题。

## 决策

- D（待协调员编号，D-25+）：N1 不用新增 `organized_at` 列，改用
  settings 表 `organizedToday` 计数（值 `yyyy-MM-dd|N`）。理由：
  questions 表没有整理完成时间字段；加列要动 Schema，而本库的
  `schemaVersion` 同时是 sqflite 的 `version`，升版本会触发
  `deleteLegacyDatabaseIfPresent` 把已有 v2 库当老库删掉（§6 第 1 条
  的删库逻辑以版本是否等于 `schemaVersion` 判断），风险不可接受；
  settings 键值复用是本项目已有做法（`lastRoute` /
  `lastRecheckReminderDate` / `backupFailed` / B11-9 的 `examEvents`），
  不碰 Schema、不碰备份表清单（settings 整表备份，计数随备份走）。
  如以后要按题反查“今天整理了哪些题”（删题回减、看明细），再立项加
  `organized_at` 列 + 专门处理 v2 库的 `onUpgrade`（不动删库逻辑）。
- D（待协调员编号，D-25+）：小结行只在“队列已空（题都在、都已整理完）”
  的空状态显示；从未有题的空状态不显示（首次使用引导态，无“今天整理
  了”的语境）。只一行，不加本周累计与连续天数。
- D（待协调员编号，D-25+）：N2 复用 `dueToday().length`，不另写口径；
  与首页焦点卡 / 复习角标同一数字。
- 注意（给协调员）：`test/b11_11_empty_states_test.dart` 的
  `_B11OrganizeRepo` 补了 `organizedTodayCount` / `dueToday` 覆盖——
  该文件会走到整理队列已空，不覆盖会调真实库方法（`AppDatabase.instance`
  会打开真实库文件并删 v1 演示库）。若第 11 项 worker 在我之后重写了
  该文件，请确认这两行覆盖还在，否则全量测试会碰真实库。另：
  b2 / b8_6 / b8_1 / b5_p2_collect 的 OrganizePage 假实现经核查走不到
  队列已空（保存是空操作、或无确认/删除动作），未动它们。
