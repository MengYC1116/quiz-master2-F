# §8 修复报告：B6 / B7 / 待定1 / 待定3

- 分支：`ui-replication`（未 commit、未 push）
- 时间：2026-11-13（Linux 真机验证当日）
- 裁决依据：B6 / B7 由 Meng 2026-11-13 14:37 裁决；待定1 / 待定3 由 Meng 2026-11-13 14:41 裁决
- 总验证：`flutter analyze` 0 问题；`flutter test` 全过 **366/366**（新增 8 个测试）；
  Linux Release 构建成功；真机截图 25 张（`docs/ui-replication/shots/s8b6b7/`，01–25 号，
  00 号纯探路截图已删）；演示库验证后已从 `/tmp/qm2-s8b6b7-orig.db` 恢复原状
  （9 道题、3 学科、深色；复核：9 题、5 道已整理、0 收集任务、0 归档、
  recent_tasks 回到种子 `整理 / 数学 / 函数极限`、无 `backupFailed` 键、无 review_state）。
- 复现脚本：`docs/ui-replication/run-shots-s8b6b7.sh`（分段：`b7 | b6 | leftover1 | leftover3 | restore`）
- 边界：不改 SQLite Schema、不改业务规则/口径（除本次裁决的四处）、不增删功能、
  不改已定决策、不升级依赖、不改 pubspec.lock；QmChip / SubjectLabel / YOLO 一概没动。

---

## B6：复习列表排除已归档已加入题

### 改了什么

- `lib/modules/review/review_page.dart` `_load()`：主列表构造循环加 `|| q.isArchived`
  （之前只有未加入列表那行排除了归档，主列表漏了）。归档题的解决记录不删，
  只在列表构造时跳过，取消归档后重新出现。
- 同文件 `_finishSession()`：总结页“还有 N 个未解决”用的 `joinedIds` 也加
  `&& !q.isArchived`，与主列表同一口径（否则归档题会虚增剩余数）。
- 未动：`repository.dueToday()`（首页“要复习”计数）保持原口径——B4.1 报告已定
  “已归档的题仍算，与 dueToday 相同”，本次不动。后果见“注意”。

### 验证

- 单测（`test/review_page_test.dart`，新增）：
  `B6：已归档的已加入题不在复习列表里，取消归档后回来`——归档态 `find.textContaining('已归档题')`
  为空，取消归档后出现；`rq()` 加 `isArchived` 参数。
- 真机（演示库，q-math-1 函数极限 已加入+已整理）：
  - 归档后复习页只剩 2 组（`09-b6-archived-review.png`）：英语 概念不清（复查）、
    数学 计算错误；数学 概念不清（函数极限）消失；元信息行变为“待解决/解决中 1 条 ·
    复查 1 条 · 已解决 0 条”。
  - 取消归档后（`12-b6-unarchived-review.png`）：数学 概念不清（函数极限）回到首行。
    图中共 4 组——第 4 组（政治 方法不会）是同一轮验证里 B7 整理确认新产生的待治组，
    不是 B6 的副作用。
- 注意：归档期间首页“要复习”仍把归档题计在内（dueToday 原口径，见上）。验证中
  归档 q-math-1 后又确认整理了 q-pol-3，首页一度显示 4 道——两者叠加所致，
  不是 B6 回归。

---

## B7：最近任务 kind 统一中文

### 改了什么

- 写入点（2 处改英文为中文）：
  - `lib/modules/collect/collect_page.dart:207/339`：`kind: 'collect'` → `kind: '收集'`
    （选文件导入、修框后生成题目两处）。
  - `lib/modules/organize/organize_page.dart:275`：`kind: 'organize'` → `kind: '整理'`
    （确认整理）。
- 读侧（`lib/data/database.dart`）：`recentTask()` 读出时经新增纯函数
  `AppDatabase.normalizeRecentKind` 归一化——库里已有的旧英文值
  `'collect'` → `'收集'`、`'organize'` → `'整理'`，映射显示，不改库、不丢数据；
  中文值与未知值原样返回。
- 首页“继续上次”核对：`home_page.dart` 的 `_normalizedKind` / `_kindPageName` /
  `_recentDescription` 本来就中英文两边都认（跳转、副标题、继续条说明三处），
  改动后仍兼容，不用改；全库只有收集/整理两处写入点 + 种子一处（种子本来就是中文 `'整理'`）。

### 验证

- 单测（新增 5 个）：
  - `test/s8b6b7_leftover_test.dart`：`normalizeRecentKind`——旧英文映射中文，
    中文与未知值原样返回。
  - `test/organize_page_test.dart`：`B7：确认整理后最近任务 kind 记中文“整理”`——
    走真实确认流程后 fake 记下的 kind 为 `'整理'`。
  - 收集写入点无 widget 测试覆盖（导入走系统文件选择器，现有测试未 mock FilePicker），
    由下面真机验证覆盖。
- 真机：
  - 旧值兼容（`01-b7-legacy-collect-home.png`）：先把库里 kind 写回 `'collect'` 再启动，
    首页显示“上次停在：收集中心 · 数学「函数极限」”与“继续上次：收集中心 · …”，
    说明“上次在这里导入了文件”。
  - 收集写入（`06-b7-collect-imported.png` / `07-b7-home-after-collect.png`）：
    选数学 → 选择文件（zenity 垫片给一张真实试卷 PNG）→ 任务出现（待框选 · 数学 ·
    文件名 · 第1页 · 第1题），导航收集角标 4→5；查库 `recent_tasks` 为
    `收集 | math | 16676QPFVu1ck984AfWQHruoHWRfTz99b.png`；首页“上次停在：收集中心”。
  - 整理写入（`10-b7-organize-confirmed.png` / `11-b7-home-after-organize.png`）：
    整理工作台确认整理 q-pol-3 后查库 `recent_tasks` 为 `整理 | politics | 材料分析：中国式现代化（整题含两问）`，
    首页显示“上次停在：整理工作台 · 政治「材料分析…」”与“继续上次：整理工作台”。

---

## 待定1：复查通过 solvedCount 超限——改成 HTML 口径，复查通过不加计数

### 改了什么

- `lib/data/repository.dart` `recordSelfCheck`：新增命名参数 `isRecheck`（默认 `false`）。
  `result == 'solved'` 且 `isRecheck` 时 `count` 取原值不 +1，且直接走已解决分支
  （只顺延复查日到今天 + 间隔天数，状态保持已解决）；普通自查仍 +1、满 `cureChecks`
  次才治愈。治愈次数规则本身没动。
- 调用方：`lib/modules/review/review_page.dart` `_finishQuestion()` 传
  `isRecheck: wasRecheck`（`wasRecheck = record.isRecheckDue`，即已解决且复查日 ≤ 今天）。
- 报告复查通过率核对：`lib/modules/report/report_page.dart` 的通过率按
  `review_history` 的 `reviewedAt` / `result` 另外算（`judged` / `passed`），
  不读 `solvedCount`，不受影响；复查通过仍会在 history 里记一条 `'solved'`，
  通过率口径不变。

### 验证

- 单测（`test/review_page_test.dart`，新增）：
  `待定1：复查通过不加计数——已满 2 次治愈后复查通过仍为 2`——复查到期的单题库
  （已解决、solvedCount=2、复查日昨天）走完四步自查“已解决”后，
  记录仍为 `solved / solvedCount=2`、复查日顺延到未来、总结出现“复查通过”。
  测试里 fake 的 `recordSelfCheck` 同步加了 `isRecheck` 语义（该文件一贯按真实语义
  实现 fake）；另修了一个测试细节：自查选项与已解决状态 pill 同名，
  复查记录上 `tapText('已解决')` 会命中两个，改为按 `QmButton` 精确定位。
- 真机（演示库 q-eng-1 学术词汇辨析：已解决、solvedCount=2、复查日 2026-11-11 已到期）：
  - 会话四步（`13–17` 号图）：看错因（“自查「已解决」2 / 2 次”+“复查 · 用原来这道题”）
    → 写补救 → 重做（答案默认隐藏，点“看答案”后显示）→ 自查（选“已解决”）。
  - 查库：`q-eng-1 | solved | solvedCount=2 | recheck_date=2026-11-20`
    （复查日从 11-11 顺延到今天 + 7 天，计数仍为 2，没有变成 3）。
  - 暂停回列表（`19-leftover1-after-recheck.png`）：英语 概念不清离开待解决列表，
    进入下方“已解决的错因”区；元信息行变为“待解决/解决中 3 条 · 已解决 1 条”，
    复查标记消失。
  - 说明：`18` 号图不是总结页——本轮会话共 4 块题，q-eng-1 是第 2 块，
    自查提交后按规则进第 3 块（“下一题”，不是“看总结”），总结页要走完 4 块才出；
    计数结论以查库为准。

---

## 待定3：首页备份失败横幅——接上

### 改了什么

- 标志：复用 settings 表 key/value（与 `lastRoute` / `lastRecheckReminderDate`
  同一做法，不新开表、不改 Schema），键 `backupFailed`，`'1'` = 有一次备份失败待提示。
  `lib/data/database.dart` 新增 `loadBackupFailedFrom` / `saveBackupFailedInto`
 （可单测的静态方法）与实例方法 `loadBackupFailed` / `saveBackupFailed`；
  `lib/data/repository.dart` 加透传 `backupFailed()` / `setBackupFailed(bool)`。
- 设置页（`lib/modules/settings/settings_page.dart` `_backup`）：写文件失败时
  （B4.2 的真写文件逻辑，判定以现行代码为准）记标志并通知应用层；
  本页原有的即时提示 `备份没存上，换个位置再试一次` 保留。另补了以前没有的
  外层 catch：导出备份或选路径本身失败时（以前异常直接外抛，既无提示也不留标志）
  同样记一次失败并弹同一提示。备份成功时清标志。
- 应用层（`lib/app.dart`）：启动时读标志进 `_showBackupError`；传给
  `HomePage(showBackupError: ..., onBackupErrorDismissed: _clearBackupError)`；
  `SettingsPage` 得 `onBackupFailed` 回调（失败当场点亮横幅，不用等重启）。
  首页（`lib/modules/home/home_page.dart`）：点“知道了”时除本地隐藏外，
  经回调清库标志（只靠本地 `_errorDismissed` 的话，切页回来状态重建、横幅会再出现）。
- 边界说明：备份导出本身含 settings 表，恢复一份带标志的备份会把横幅带回来一次，
  点“知道了”即清——可接受，未另做处理。

### 验证

- 单测（`test/s8b6b7_leftover_test.dart`，新增 2 个）：
  标志在演示库临时副本里往返（默认无 → 置起读到 true → 清掉读到 false）；
  标志键与 `lastRoute` / 提醒键不同。
- 单测（`test/home_page_test.dart`，新增 1 个）：
  点“知道了”调 `onBackupErrorDismissed` 且横幅消失。
- 真机（zenity 垫片：`--save` 返回不存在的目录 `/tmp/qm2-no-such-dir/`，
  写文件必失败，模拟备份失败）：
  - `22-leftover3-backup-failed-snack.png`：设置页底部即时提示
    “备份没存上，换个位置再试一次”；查库 `backupFailed=1`。
  - `23-leftover3-home-banner.png`：切到首页，顶部红色横幅出现，文案为 HTML 原文
    “本地数据备份失败：磁盘空间不足，新收集的题目已保存在本地库中，
    但这次手动备份没有完成。请清理磁盘后在「设置」中重新备份。”，带“知道了”。
  - `24-leftover3-home-dismissed.png`：点“知道了”后横幅消失；查库 `backupFailed=0`。
  - `25-leftover3-home-after-restart.png`：杀掉重进，首页不再出现横幅。

---

## 改动清单（相对本次开工时的脏工作区，只列本任务动的文件）

| 文件 | 改动 |
|---|---|
| `lib/modules/review/review_page.dart` | B6 主列表 + 总结剩余数排除归档；待定1 传 `isRecheck` |
| `lib/data/repository.dart` | 待定1 `recordSelfCheck(isRecheck)`；待定3 标志透传 |
| `lib/data/database.dart` | B7 `normalizeRecentKind` + 读侧归一化；待定3 `backupFailed` 键 |
| `lib/modules/collect/collect_page.dart` | B7 两处 `'collect'` → `'收集'` |
| `lib/modules/organize/organize_page.dart` | B7 `'organize'` → `'整理'` |
| `lib/modules/home/home_page.dart` | 待定3 `onBackupErrorDismissed` 回调 |
| `lib/app.dart` | 待定3 标志状态 + 分发给首页/设置页 |
| `lib/modules/settings/settings_page.dart` | 待定3 `_backup` 失败记标志、成功清标志、外层 catch |
| `test/review_page_test.dart` | B6 测试、待定1 测试、fake 同步、`rq()` 加归档参数 |
| `test/organize_page_test.dart` | B7 整理写入 kind 断言 |
| `test/home_page_test.dart` | 待定3 点“知道了”调回调测试 |
| `test/s8b6b7_leftover_test.dart`（新增） | B7 归一化、待定3 标志往返 |
| `docs/ui-replication/S8B6-B7-LEFTOVER-REPORT.md`（本文件） | 报告 |
| `docs/ui-replication/run-shots-s8b6b7.sh`（新增） | 真机复现脚本 |
| `docs/ui-replication/shots/s8b6b7/`（新增 25 张） | 截图 |

## 待确认 / 遗留

- 无新增阻塞。四项均按裁决完成，analyze 0、测试 366/366、Linux 真机验证通过。
- Linux 结果不替代 Win11 最终验收：字体/DPI/原生资源仍须 Meng 在 Win11 真机复核
  （与 R11 结论一致）。
- 工作区仍有本次开工前就存在的其他未提交改动（B2 补充、B4 等），本次未碰、未提交、未推送。
