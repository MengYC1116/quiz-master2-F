# P0B1 归档口径统一（第一批第 3 项）+ 错题本切片占位传 subject — 修复报告

- 日期：2026-11-13
- 分支：`ui-replication`（未 commit、未 push）
- 基线：开工时工作树已含 §8 完成态 + 第 1 项错题本刷新 + 第 2 项学科同步扫尾的未提交改动；基线验证 `flutter analyze` 0 问题、全量 `flutter test` 398 项全部通过（397 通过 + 1 跳过），与任务书一致，遂按任务继续。

## 1. 主任务：归档口径统一

### 背景（已按文件核实）

复习页 B6 主列表排除已归档题（`review_page.dart` 约 L197-200，`if (!q.reviewJoined || !q.isOrganized || q.isArchived) continue`；`_finishSession` 约 L548-555 另有内联 `!q.isArchived` 过滤），但仓库里三个计数仍用 `all(includeArchived: true)`：

| 方法 | 原口径 | 影响面 |
| --- | --- | --- |
| `dueToday()`（`repository.dart` 约 L59） | 含归档 | 首页焦点卡、首页学科格 |
| `homeRevCounts()`（约 L81，经 `dueToday()`） | 含归档 | 首页、导航速览（`app.dart` `_refreshBadges` → `AppNavBar.navRev`） |
| `recheckDueCauseCount()`（约 L331） | 含归档 | 复查提醒（`app.dart` `_maybeShowRecheckReminder`） |
| `subjectCounts()`（约 L99） | 含归档 | 错题本封面三数（题数 / 要复习 / 待复查） |

### 改了什么

只改 `lib/data/repository.dart`，三个方法各加 `includeArchived` 参数，默认排除归档；调用方（首页 `dueToday()`、`homeRevCounts()`，`app.dart` 的提醒与速览）走默认值即已统一，无需改调用点；复习页本身已是排除口径，未动。

- `dueToday({bool includeArchived = false})`：`all(includeArchived: includeArchived)`；注释写明“已归档的题不算（与复习页 B6 主列表同口径；记录保留在库里，取消归档后重新计入）”。
- `recheckDueCauseCount({bool includeArchived = false})`：同上；注释里“已归档的题仍算，与 dueToday 相同”已随之作废，改为“已归档的题不算”。
- `subjectCounts({bool includeArchived = false})`：同上。**说明：这是任务点名的四处（首页 / 导航速览 / 复查提醒 / 复习列表）之外的一处**——错题本封面“要复习 / 待复查”同样是“要复习”数字，归档题计入会与复习列表对不上，故按同一模式一并改了；如需回退，只改这一行回 `includeArchived: true` 即可。`wrongbook_page.dart` 的调用 `subjectCounts()` 未动。
- 顺带一处（`dueToday` 内）：`_db.allCauseRecords()` 改为仓库方法 `causeRecords()`，与 `subjectCounts` 已有的做法同款（语义同义，便于单测覆盖；不改它就没法用 Fake 测 `dueToday`）。其余 `_db.allCauseRecords()` 直读处（`syncCauseRecords` 等）未动。
- 未动数据库 Schema、未改依赖、未动 `pubspec.lock`、未 commit/push/pull/reset/checkout/clean。

### 新增回归测试

`test/p0b1_archived_counts_test.dart`，7 项（Fake 仓库的 `all()` 按 `includeArchived` 真过滤，与真实 `all()` 同行为）：

1. `dueToday`：归档后排除；显式 `includeArchived: true` 仍包含；取消归档恢复计入；
2. `homeRevCounts`（首页 + 导航速览）：归档后数学计数 1→0，取消归档恢复 1；
3. `recheckDueCauseCount`（复查提醒）：已解决且到复查日的错因，归档后 0、`includeArchived: true` 时 1、取消归档恢复 1；
4. `subjectCounts`（错题本封面三数）：两题场景（待解决 1 题 + 已解决到复查日 1 题）逐题归档，三数按预期归零，取消归档恢复；
5. 未加入复习 / 未整理的题本来就不计，改动不影响；
6. 错题本大卡片 `QuestionSlice`：见 §2；
7. 错题本紧凑列表 `CompactSliceThumb`：见 §2。

另有 3 处既有测试替身的机械兼容改动（Dart 覆盖要求新命名参数）：`test/home_page_test.dart:93` 与 `test/s8b2_subject_sync_test.dart:74` 的 `dueToday()`、`test/wrongbook_page_test.dart:108` 的 `subjectCounts()` 各补 `{bool includeArchived = false}`，行为不变。

## 2. 附加小项：错题本切片占位传 subject

第 2 项按要求没动错题本，`wrongbook_page.dart` 三处切片调用点仍未传 `subject`，新学科在失败占位里仍显示成“数学”；widget 侧参数已就绪。本次仅改这三处，除此以外未动错题本其他代码：

| 调用点 | 位置 | 改动 |
| --- | --- | --- |
| 大卡片 `QuestionSlice` | `_buildLargeCard`，约 L2850 | 加 `subject: _subjectOf(q.subjectId)` |
| 紧凑行 `CompactSliceThumb` | `_buildCompactRow`，约 L2971 | 同上 |
| 已归档行 `CompactSliceThumb` | `_buildArchivedRow`，约 L3114 | 同上 |

`_subjectOf` 是错题本已有的读库方法（约 L51，`_subjects` 里找，找不到才回退 `Subject.byId`）。

回归测试（`test/p0b1_archived_counts_test.dart` 后两项，页级）：用含新学科化学的 `FakeWrongbookRepo` 泵起整页错题本，进化学书 → 全部题目，直接读树上 widget 的 `subject` 参数断言——大卡片 `QuestionSlice.subject` 为化学（id `subject-chem`、名“化学”、图标“化”）；切到紧凑列表后两处 `CompactSliceThumb.subject` 均为化学。失败占位本身的渲染（`failed: true` 时显示“化”+“化学 · 极限题”/“加载失败”）已由 `p0b1_subject_sync_test.dart` 的切片占位测试覆盖；错题本页本身不传 `failed`，真机上走不到失败占位（见 §4 第 5 点）。

## 3. 验证证据

- `flutter analyze`：**0 问题**（改前基线与改后各跑一次，均为 0；中途曾出 2 个 warning——新测试文件的未用 import 与未用 `show` 名，已清掉再跑回 0）。
- `flutter test` 全量：改前 398 项全部通过（397 通过 + 1 跳过）；改后 **405 项全部通过（404 通过 + 1 跳过）**，新增 7 项即本组；单文件 `test/p0b1_archived_counts_test.dart` 7/7 通过。
- 真机（Linux 虚拟机，Xvfb 1280×720，深色，`flutter build linux --release` 现场构建；构建仍用上次的 `/tmp/gtk-sysroot` 办法，未动 dpkg）：新建化学学科 + 化学题「化学平衡」（错因 概念不清 + 计算错误；计算错误预置已解决且复查日为昨天），加入复习与归档均走详情页 UI。截图在 `docs/ui-replication/shots/p0b1-archived/`（化学学科相关在 `subject/` 子目录）。

| 状态 | 首页“要复习” | 导航速览化学 | 复查提醒 | 复习列表 | 错题本化学封面 |
| --- | --- | --- | --- | --- | --- |
| 基线（题未加入复习） | 3 道（待解决 2 · 复查 1） | 待复习 0 | 1 个错因 | 无化学行 | 1 道题 / 0 要复习 / 0 待复查 |
| 加入复习后 | **4 道**（待解决 3 · 复查 1） | 待复习 **1** | **2 个错因** | 化学两行（概念不清 待解决、计算错误 复查/已解决） | 1 / **1** / **1** |
| 归档后 | **3 道**（待解决 2 · 复查 1） | 待复习 **0** | **1 个错因** | 无化学行（共 3 条，复查 1 条） | **0** / **0** / **0**，已归档 (1) |
| 取消归档后 | **4 道** | 待复习 **1** | （未重测启动提醒，见 §4） | （未重测，计数已恢复） | （未重测） |

截图与状态对应：基线 `01-reminder-baseline.png`（提醒 1 个错因）、`02-home-baseline.png`（3 道）；加入后 `06-detail-joined.png`（已加入复习 · 还有 1 个错因未解决）、`07-home-joined.png`（4 道）、`07b-back-to-list.png`（化学待复习 1）、`08-review-joined.png`（化学两行）、`09-reminder-joined.png`（提醒 2 个错因，重启后）；归档后 `11-detail-archived.png`（已归档横幅）、`12-home-archived.png`（3 道）、`13-review-archived.png`（无化学行）、`14-reminder-archived.png`（提醒 1 个错因，重启后）、`15-archived-list.png`（已归档列表 1 道）；恢复后 `16-home-restored.png`（4 道）。`subject/` 下：`01-shelf-chem.png`（书架化学封面）、`02-chem-directory.png`（目录：全部题目 1 道）、`03-chem-list.png`（大卡片）、`04-chem-compact.png`（紧凑列表）。

- 演示库验证后已恢复：`~/.local/share/quiz-master2/quiz-master2.db` 与跑前备份 `/tmp/qm2-p0b1-archived-orig.db` md5 一致（`963eb66ee68a2a4e820f2bd023266123`），9 道题、3 学科、0 归档、`notifyTime` 回到 20:00。杀应用只用 `pkill -x quiz_master2`。

## 4. 偏离与说明

1. **“新建一道题”的新建步骤走了数据库直插，不是应用内收集。** 应用无手动录入入口（已确认决策），收集需文件导入；为拿到一道带指定错因 / 复查日的可控新题，直接往工作库插了学科、文件夹、题目与一条已解决错因记录，再走 UI 做加入复习与归档。新建题的加入、归档、恢复三个动作本身均走 UI；直插内容随演示库恢复已清除。
2. **复查提醒的真机验证改了工作库的 `notifyTime`。** 虚拟机时钟是 UTC（约 15:00），未到默认 20:00，提醒不会弹；把工作库 `notifyTime` 临时改为 00:00，并每次重启前清掉 `lastRecheckReminderDate`（一天一次的键），才让三次启动各弹一次。恢复演示库后 `notifyTime` 已回到 20:00。
3. **交互中误点一次，已恢复重做。** 加入复习后点底部“返回错题本”时点中了位置上移的「取消加入复习」，题被取消加入（库里 `review_joined` 回到 0）；发现后重新点「加入复习」并以库值核实（`review_joined=1`），其后截图 `07/08/09` 均为重做后的正确状态。另有一次批量点击走偏到整理工作台（对话框关闭后首个点击偶尔被吞，见第 4 点），那次拍的错图已删除，按步重走。
4. **对话框关闭后第一个导航点击偶尔被吞。** 两次在点「稍后再说」后紧接着点左导航无反应，再点一次即正常。疑似焦点 / 动画问题，未深究；本次只在验证脚本里记下，未改代码。
5. **真机上无法让错题本切片走到失败占位。** `QuestionSlice` / `CompactSliceThumb` 的失败占位由 `failed` 开关控制，错题本页三处调用点都不传 `failed`（详情页才传）；真机截图 `subject/03/04` 只能证明切片正常渲染且带化学紫色框，失败占位传参的正确性由 §2 的页级 widget 测试（读树上 `subject` 参数）+ `p0b1_subject_sync_test.dart` 的 `failed: true` 替身渲染测试共同覆盖。
6. **化学封面顶部的英文仍是 “MATHEMATICS”。** 新学科封面中文名、紫色、题数均正确，但封面英文行未随学科变（疑似封面样式按固定表取英文名）。本次未动封面样式代码，属既有行为，记在这里供 Meng 定是否另立一项。
7. **取消归档后只复核了首页。** 恢复计入在首页（4 道、化学待复习 1）与库值（`is_archived=0, review_joined=1`）上已证实；复习列表与提醒的恢复态未再重启复核——二者与首页同走 `dueToday` / `recheckDueCauseCount`（回归测试已覆盖恢复分支），风险低。
