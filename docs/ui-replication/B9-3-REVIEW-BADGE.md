# B9-3：左导航“复习”角标

Meng 2026-11-15 ~17:41 新报（截图 image-102）：左导航“复习”没有角标，要求加上。
本项已完成，未提交、未推送（第九批保持开放）。

## 一、口径核对

### 共享口径（角标用的就是它）

角标数字 = **要复习的题数**，与首页焦点卡“要复习的数量”是同一个数：

| 位置 | 口径 |
|---|---|
| `QuestionRepository.reviewBucketOf`（`lib/data/repository.dart:30`） | 一道题按全部错因记录互斥分类：`pending`（≥1 个错因未解决）/ `recheck`（全部已解决且 ≥1 条到复查时间）/ `solved` / `none` |
| `dueToday()`（`repository.dart:101`） | 手动加入复习、已整理、桶落在 `pending` 或 `recheck` 的题；**数题不数错因**；已归档不算 |
| `homeRevCounts()`（`repository.dart:124`） | 每科要复习题数（`dueToday()` 按科拆分） |
| 首页焦点卡（`lib/modules/home/home_page.dart:120-161`） | `dueToday().length`，拆成 待解决（`pending`）+ 复查（`recheck`）两项，相加 = 总数 |

角标实现：`_refreshBadges` 里取 `homeRevCounts()` 各科之和（= `dueToday().length`）。
0 时行为：沿用现有条件 `if (item.badge > 0)` 才渲染（`app_shell.dart:416` 展开态、`:463` 折叠态），0 时隐藏，与收集/整理角标一致。

### 与复习页顶计数的差异（必须单独说明，未改）

复习页顶那句“待解决 / 解决中 N 条解决记录”里的 N 来自 `_metaCounts`
（`lib/modules/review/review_page.dart:407`），它是**按错因条数计**的：
`_groups` 里每条 cause 记录算一条（到复查时间的另计入“复查 M 条”），
已解决的另计“已解决 K 条”。而角标 / 首页焦点卡是**按题数计**。
一道题有多个待解决错因时，两处数字不一样。

例子（以截图用 v2 演示库的真实数据为准）：

- 演示库 9 道题里，`q-math-1`（数学，1 个待解决错因）与 `q-math-3`
  （数学，1 个待解决错因）待复习，另有 `q-eng-1`（英语，错因已解决，
  复查日 `recheck_date` = 2026-11-13 11:11 UTC，**已到复查时间**）：
  角标 = **3**（待解决 2 + 复查 1），复习页顶“待解决 / 解决中 **2** 条
  解决记录”+“复查 **1** 条”——总数对得上（3 = 2 + 1），页顶只是把
  两类拆开了。
  - 订正（2026-11-15 接手核对）：初稿这里写的是“`q-eng-1` 未到复查
    时间，角标 = 2”，是错的。`q-eng-1` 的复查日 2026-11-13 早已到；
    截图脚本里那条 SQL 当时也只数出 2，是因为它用 `date(recheck_date)`
    直接比——`recheck_date` 存的是**毫秒 epoch**整数，`date()` 会把它
    当成儒略日，复查项被漏掉。脚本已改成毫秒口径（`recheck_date <=
    strftime('%s','now')*1000`），重数得 **3**，与应用一致。
- 若某题有 **2 个待解决错因**（如测试种子 `q1`：概念不清 + 计算错误），
  再加一道 1 个待解决错因的题：角标 = **2**（两道题），
  复习页顶 = “待解决 / 解决中 **3** 条解决记录”（三条错因记录）。
  测试 `test/b9_3_review_badge_test.dart` 已把这个口径锁死（见 §四）。
- 复查场景：某题全部错因已解决、其中 1 条到了复查时间：角标计 **1**，
  复习页顶 pend 计 0、“复查 **1** 条”——总数仍对得上（角标 = pend 题数
  + recheck 题数），只是页顶把两类拆开了。

所以任务书里“就是复习页顶的 N，也是首页焦点卡的数量”这个说法，
**只在每道题恰好一个待解决错因、且无复查项时成立**。
本次处理：角标用共享口径（按题数，与首页一致）；复习页顶的计数不动。
**已裁决（Meng 2026-11-15 ~19:43，点“统一，复习页顶也按题数”）：
复习页顶统一按题数**，见 B9-4（`docs/ui-replication/B9-4-REVIEW-HEADER-COUNT.md`），
本报告 §七第 1 项同步更新。

## 二、接线

### 改动文件（共 3 个）

| 文件 | 改动 |
|---|---|
| `lib/app.dart` | 新增 `_reviewBadge` 字段；`_refreshBadges` 里 `_reviewBadge = rev.values.fold(0, (a, b) => a + b)`（`rev` 就是已读的 `homeRevCounts()`）；`_buildNav` 传 `reviewBadge: _reviewBadge` |
| `lib/widgets/app_shell.dart` | `AppNavBar` 新增 `reviewBadge` 参数（默认 0）+ 字段注释；复习的 `_NavItemData` 加 `badge: reviewBadge`；文件头角标口径注释补一行 |
| `test/b9_3_review_badge_test.dart` | 新增（7 个用例，见 §四） |

样式：复用现有 `_NavBadge`（`app_shell.dart:480` 起），没有新画。
展开态与折叠态共用 `_navItems()`，所以两态天然一致；
0 时隐藏由两处现成的 `if (item.badge > 0)` 保证。

### badgeGrey 选择：accent（默认 false，与整理工作台一样）

理由：

1. 收集角标用灰（`badgeGrey: true`）是因为它是混合信息数
   （待框选 + 待整理），不是单纯的“待办”；整理与复习都是明确的
   “待办”数——有多少事等着你去做，用 accent 档在视觉上就是待办。
2. 与 HTML 原型一致：`.bdg` 默认就是 accent 底，只有收集角标是
   `.bdg.grey`；复习按默认走，不用例外。
3. 选中态下角标本来就走 `badgeSelectedBg/Fg` token（亮 `#FFFFFF/#175CD3`、
   深 `#D5DBE4/#33465A`），与 `badgeGrey` 无关，选中态表现不受选择影响。

## 三、触发点清单

角标刷新靠两条线，与收集/整理角标完全相同：(a) 数据层写库后
`bumpBadgeVersion()` → `badgeVersion` 监听 → `_refreshBadges`；
(b) 每次导航（`_go` / `_goReview` / `_goWrongbookFiltered` /
`_openDetail` 后）直接调 `_refreshBadges`；详情页 `onChanged`
也接它；启动时 `initState`（`app.dart:96-98`）跑一次。

逐一核对复习状态变化的点：

| 状态变化 | 写库入口 | bump？ | 结论 |
|---|---|---|---|
| 加入 / 取消加入复习 | `setReviewJoined`（`db_questions.dart:405`，`if (ok) bumpBadgeVersion()`） | ✅ | 覆盖 |
| 自查已解决 / 未解决 / 治愈 | `recordSelfCheckTxn`（`db_questions.dart:440`，`result != 'unsure'` 时 bump） | ✅ | 覆盖；“不确定”不写库、不 bump 是对的——状态没变 |
| 写补救 | `updateCauseRemedy`（`db_questions.dart:396`） | ✅ | 覆盖（不改变桶，多余但无害的刷新） |
| 详情页改错因（增/删错因） | `syncCauseRecords` 本身不 bump，但两个调用点前都有 `repo.save` → `upsertQuestion`（`:497`）先 bump | ✅ | 覆盖（`detail:375`、整理页 `:299/:351` 前都有 `save`；若将来有人单调 `syncCauseRecords` 会漏，见备注） |
| 整理确认 / 批量整理 | `db_collect.dart:597/:613/:647/:667/:691` | ✅ | 覆盖（整理本身不直接改变复习桶——未整理题加不进复习；刷新是顺带的） |
| 删题 | `deleteQuestion`（`:503`） | ✅ | 覆盖 |
| 归档 / 取消归档 | `archive` → `upsertQuestion`（`:497`） | ✅ | 覆盖 |
| 删学科（连带删题） | `db_catalog.dart:428/:434/:491/:513` | ✅ | 覆盖 |
| 备份恢复 / 设置写库 | `db_settings.dart:118` | ✅ | 覆盖（恢复备份可能改题） |
| **复查到期（时间驱动）** | 无写库动作 | ❌ 无 bump | 见下评估 |

**复查到期评估：现有触发点够用，不另加。**复查到期只发生在日期
跨过 `recheckDate` 时，没有任何写库动作可挂 bump；但角标会在以下
时机刷新：应用启动（`initState` 的 `_refreshBadges`）、每一次切导航
（`_go` 等四处）、任何一次写库（bump 监听）。唯一残留的滞后窗口是：
应用一直开着跨过午夜、且期间没有任何导航或写库——角标会滞后到下一
次导航/写库才变过来。复习页本身每次打开都重读库，页内数字不受影响；
复查提醒弹框也只在启动时判断一次（B4.1），与角标无关。这个窗口与
“用户整夜不碰应用”重合，影响可忽略，故不补触发点。

备注：`syncCauseRecords`（`db_questions.dart:411`）与
`deleteCauseRecordsForQuestion`（`:444`）本身不 bump；前者目前每次
调用前都有 `save` 兜底，后者无生产调用方（删题走 `deleteQuestion`
的 `:503`）。若将来有调用方单调 `syncCauseRecords`，需补 bump——
不在本项范围。

## 四、测试

新增 `test/b9_3_review_badge_test.dart`，7 个用例，全部通过
（`flutter test test/b9_3_review_badge_test.dart --concurrency=1`，
7/7，接手复核约 4 秒）。

### A 组：纯展示组件 `AppNavBar`（参数驱动，不读库）

| 用例 | 结果 |
|---|---|
| `reviewBadge=3` 显示 `3`，accent 底（不是灰档） | ✅ |
| `reviewBadge=0` 时不渲染 | ✅ |
| 折叠态下角标同样显示 | ✅ |
| 选中复习页（`/review`）时角标用 `badgeSelected` token（亮 `#FFFFFF/#175CD3`） | ✅ |

### B 组：真实内存库 + 整应用 `QuizMasterApp` 真实交互

种子：数学 `q1`（2 个待解决错因：概念不清、计算错误）+ `q2`
（1 个待解决错因：审题失误），两题均已整理、已加入复习。

| 用例 | 结果 |
|---|---|
| 多错因一题只计 1：两道待复习题角标是 2 不是 3（`dueToday()` 长度 2；`q1` 的错因记录 2 条；注释写明与复习页顶按条数计的区别）+ 折叠/展开后角标仍是 2 | ✅ |
| 治愈一条后角标即减一：治愈 `q1` 两错因后只切导航（首页 → 收集中心 → 首页，不进复习页），角标变 1；再治愈 `q2`，角标隐藏（0 不渲染），`dueToday()` 为空 | ✅ |
| 取消加入复习后角标即减：取消 `q1` 加入复习后只切导航，角标变 1 | ✅ |

### 全量测试

未在本项内跑（留待批末，见 §五）。另：第 1 项的
`test/b9_1_collect_done_test.dart` 已单独重跑，**7/7 通过**
（见 §五）。

## 五、验证结果

### 本项级验证（已过，2026-11-15 18:04–18:16 CST / 10:04–10:16 UTC）

- `flutter analyze`：**0 问题**（接手后复核，前人“0 问题”的结论属实；
  前人已修掉 1 个 info：测试文件里 `design_tokens.dart` 导入多余，
  `app_theme.dart` 已再导出）。
- 本项测试串行 `--concurrency=1`（默认 `/tmp`，未改 `TMPDIR`，
  `LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`）：
  - `test/b9_3_review_badge_test.dart`：**7/7 通过**（约 4 秒）——§四
    的 7 个用例逐条复核通过（N 显示、0 隐藏、治愈后减一、只切导航即更
    新、折叠态显示、多错因一题只计 1、取消加入即减）。
  - 相关文件：`test/app_shell_test.dart` **18/18**、`test/home_page_test.dart`
    **18/18**、`test/review_page_test.dart` **39/39**，全部通过。
- 第 1 项单独重跑：`test/b9_1_collect_done_test.dart` **7/7 通过**
  （接手人亲跑，约 13 秒，`All tests passed!`）。该文件在 10:14 UTC
  又被第 1 项工人改过一次（新增第 7 个用例“批量确认”），本次跑的是
  改后的文件。
- 截图用 Linux Release 构建：改后二进制 `flutter build linux --release`
  成功（10:06 UTC）；改前二进制由 `prep-before-tree.sh` 在
  `$HOME/b9-3-before` 构建成功（10:11 UTC，`reviewBadge` 出现 0 次，
  接线确已剥离）。**但这只是截图用的构建，不是批末门禁构建**（见下）。

### 留待批末树静止后统一做的门禁（本项未做，不冒充已过）

- **全量测试串行 `--concurrency=1` + Linux Release 构建 + 演示库恢复核对，
  全部留待批末。**原因：第 1、2 项工人与本项同时在同一棵树上跑——
  第 2 项工人约 10:08 UTC 已起了一个全量跑（`~/workspace/demo-db-backup/b9-2-full.log`，
  本项收尾时进行中），此时再起全量会争内存、撞构建缓存（Batch 8 就爆过
  一次内存）；树也在动，全量结果不稳定。批末树静止后由协调人统一跑
  一次门禁为准。
- **`~/workspace/demo-db-backup/b9-3-full.log` 作废，不作为通过证据。**
  它跑到 +879 后在加载 `test/b9_1_collect_done_test.dart` 时出 `[E]`
  并以 `Bad state: Cannot close sink while adding stream` 的 shutdown
  报错结束——当时第 1 项工人正在改那个文件，树在动，这个结果不能算
  通过。同样的挂起在接手核对时又出现过一次：第 1 项工人 10:01 UTC
  的那次单跑在第 6 个用例后约 10 分钟无输出、进程仍活着；当时文件
  仍在改（10:14 又改过一次），文件改定后的新跑 7/7 即过——挂起是
  改动进行中导致，不是不通过的产品问题。
- 演示库：跑全量前备份 live 库到
  `~/workspace/demo-db-backup/quiz-master2.db.b9-3-start`
  （md5 `8f7f9c64405dc6e484ac2bf8e5e1a807` = v1，已核对）。
  **本项没有恢复 live 库。**本项工作期间 live 库被其他工人动过
  （中途 md5 一度变为 `9cae0d09…`、`e81147c0…`），截图结束时又回到
  v1（`8f7f9c64…`，应是其他工人恢复的，非本项操作）；批末树静止后
  仍需统一恢复并核对一次，以批末门禁为准。

## 六、截图

`docs/ui-replication/shots/b9-review-badge/`（不推）：

| 文件 | 内容 |
|---|---|
| `00-before-expanded.png` | 改前（无角标）展开态 |
| `01-before-collapsed.png` | 改前（无角标）折叠态 |
| `02-after-expanded.png` | 改后（角标 3）展开态 |
| `03-after-collapsed.png` | 改后（角标 3）折叠态 |

4 张 PNG 均已落盘并目视核对：改前两张复习项无角标、首页仍显示
“3 道要复习”（角标是唯一差别）；改后两张复习项角标都是 **3**
（展开态文字旁、折叠态图标右上角），与首页焦点卡“3 道要复习
（待解决 2 道 · 复查 1 道）”及学科速览（数学 2、英语 1）一致。
修脚本后重跑一次，4 张 PNG md5 与第一次完全相同（可复现）。

截图脚本：`run-shots-b9-3.sh`（Xvfb `:97` + 隔离 HOME
`$HOME/b9-3-home` + v2 演示库副本，live 库未动）；
改前二进制由 `prep-before-tree.sh` 在 `$HOME/b9-3-before`
备好（整树拷贝、只精确删掉 B9-3 的 3 处接线，其余与工作树一致；
绝不动真工作树、不动 git 历史）。
演示库待复习 **3** 道（`q-math-1`、`q-math-3` 待解决，
`q-eng-1` 复查到期 2026-11-13），所以改后角标是 **3**。
（初稿写 2 道/角标 2 是错的，见 §一订正。）
两处路径改到 `$HOME` 下的原因：`/tmp` 是 512M tmpfs，改前树拷贝 +
构建产物放不下（备改前树时报过 `No space left on device`）；另补了
`tar --no-same-owner`（家目录文件系统上解包时 chown 被拒）。

## 七、已裁决（原“待 Meng 定夺”，2026-11-15 ~19:43 更新）

1. **复习页顶口径已裁决：统一按题数**（Meng 点“统一，复习页顶也按题数”）：
   角标/首页按题数，复习页顶原按错因条数（见 §一）。B9-4 已落地：
   复习页顶“待解决 / 解决中 N 条解决记录”改成按题数（“N 道题”，
   复查/已解决同步改成“道”），见 `docs/ui-replication/B9-4-REVIEW-HEADER-COUNT.md`。
2. 本项未碰：`B9-SUMMARY.md` 未写，完成邮件未发（第九批保持开放）。
