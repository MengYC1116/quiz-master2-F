# S8 B4 报告：通知提醒（B4.1）+ 备份补 4 张表（B4.2）+ 数据库位置迁移旧库（B4.3）

- 日期：2026-11-13
- 分支：`ui-replication`（未提交、未推送，按任务要求）
- 结论：三项全部完成并通过验证。`flutter analyze` 0 问题；`flutter test` 全量 358/358 通过（含新增 20 个测试）。
- 演示库已恢复原状：9 道题、3 学科、深色、启动页 home、提醒开关开（默认）、提醒时间 20:00（默认）、无 `db_location.txt` 标记文件。

## B4.1 通知提醒（应用内提醒）

### 做了什么

- 新增 `lib/services/recheck_reminder.dart`：纯函数 `shouldShowRecheckReminder`，四条全满足才弹：
  1. 通知开关开着（设置 #20 `notifyEnabled`，默认开）；
  2. 有错因到了复查时间（`CauseRecord.isRecheckDue`：已解决且复查日 ≤ 今天；计数走仓库新方法 `recheckDueCauseCount()`，数错因不数题，口径与 `dueToday()` 一致——只算已加入复习、已整理的题）；
  3. **已到当日提醒时间**：进应用时判断 `now >= 今天 notifyTime`（含整点那一刻）；没到点不提醒，等下次进应用时再判断。`notifyTime` 写坏了（如 `'abc'`）按默认 20:00 算，不崩；
  4. **一天一次**：提醒过的日期存在 settings 表 key `lastRecheckReminderDate`（`yyyy-MM-dd`，与 B3 的 `lastRoute` 同一做法，复用 settings 表，不新开表、不改 Schema）；弹之前先写日期，当天重进不再弹。
- `lib/app.dart`：设置读到后、首帧后判断一次（`_maybeShowRecheckReminder`，一轮应用只判断一次，切页不重复弹）。弹现有 `AlertDialog`（不新引通知依赖、不接系统通知）：标题“该复查了”，内容“有 N 个错因到了复查时间，去复习看一下吧。”，按钮“去复习”（进复习页）/“稍后再说”（只关掉）。读库失败时静默跳过，不影响启动。
- 新增 `AppDatabase.load/saveLastRecheckReminderDate`、`QuestionRepository.recheckDueCauseCount / lastRecheckReminderDate / saveLastRecheckReminderDate`。

### 验证

- 单测 `test/s8b4_reminder_test.dart`（11 个）：开关关、错因数 0、提醒时间前、提醒时间后、整点那一刻、今天已提醒过、昨天提醒过今天没提醒、提醒时间写坏回落 20:00、日期串格式、仓库计数只数已加入+已整理题上的到期错因。
- 真机（Linux Release，Xvfb 1280×720，深色，演示库有 1 个到期错因：英语“概念不清”）：脚本 `docs/ui-replication/run-shots-s8b4-b41.sh`。

| 场景 | 设置 | 结果 | 截图 |
|---|---|---|---|
| 提醒时间已过（00:00） | 开关开 | 弹出，文案“有 1 个错因到了复查时间”，库里写下 `lastRecheckReminderDate=2026-11-13` | `shots/s8b4/01-reminder-shows.png`、`03-reminder-shows-again.png` |
| 点“去复习” | — | 进复习页（`lastRoute=/review`），列表里英语“概念不清”标“复查” | `shots/s8b4/04-reminder-go-review.png` |
| 点“稍后再说” | — | 关掉，仍在首页（`lastRoute=/home`） | `shots/s8b4/08-reminder-dismiss.png` |
| 同一天重进 | 开关开、00:00 | 不弹 | `shots/s8b4/05-no-repeat-same-day.png` |
| 开关关掉 | 关、00:00（已清当日记录） | 不弹 | `shots/s8b4/06-disabled-no-reminder.png` |
| 提醒时间未到 | 开、23:59（已清当日记录） | 不弹 | `shots/s8b4/07-before-time-no-reminder.png` |

- 小插曲：第一次点“去复习”时按目测坐标 (705, 413) 点到了“稍后再说”文字右缘与按钮之间的空隙，对话框没反应；裁剪放大后量得按钮中心实为 (775, 402)，重跑后一次点中。不是应用问题，是量坐标的方法问题（后续都先裁剪量准再点）。

## B4.2 备份补 4 张表

### 现状确认（改前）

- `exportBackupJson`（`lib/data/database.dart`）只导 8 张表，缺 `collect_tasks` / `review_state` / `review_history` / `recent_tasks`。
- 恢复（`settings_page.dart` `_confirmRestore`）删除清单里已有这 4 张表，但重插清单 `_backupTables` 只有 8 张——旧备份恢复后这 4 张表会被清空且不回来。另发现删除清单还缺 `collect_tasks`，旧收集任务会在恢复后残留。

### 做了什么

- `AppDatabase.backupTables`（静态常量，共 12 张表）：导出与恢复共用，恢复只插这里的表。
- `exportBackupJsonFrom(db)` / `importBackupJsonInto(db, data)`（可单测版）+ 实例方法 `exportBackupJson()` / `importBackupJson(data)`；设置页恢复改为调 `widget.repo.importBackupJson(data)`，删除逻辑随之统一（12 张表全清，含 `collect_tasks`）；旧备份（没有 4 张表键）恢复不崩，这 4 张表被清空。
- **顺带修了一个旧 bug（验证中发现，B4.2 验收流程必需）**：`_backup()` 原来只把 `bytes:` 传给 `FilePicker.platform.saveFile` 就弹“备份已保存”。查 file_picker 8.3.7 源码确认：桌面端（Windows/macOS/Linux）`saveFile` 只返回选好的路径，**不写文件**——`bytes` 只在移动端走通道写文件，Linux 实现直接忽略 `bytes`，macOS 传了还会抛错。也就是说旧备份按钮在 Win11 上点了也是“假保存”。改成：拿到路径后自己 `File(path).writeAsBytes(bytes)`，写失败提示“备份没存上，换个位置再试一次”；不再传 `bytes:` 参数。只修这一处，不改备份的入口、文案和流程。

### 验证

- 单测 `test/s8b4_backup_migration_test.dart`（B4.2 部分 4 个）：表清单含 4 张表共 12 张；演示库临时副本（只读复制，不碰真库）里 4 张表各放 1 行标记数据 → 导出 JSON 含 4 张表数据 → 清掉 → 恢复 → 4 张表数据回来，其余表不受影响（仍 9 道题）；旧备份恢复不崩、4 张表被清空。
- 真机：脚本 `docs/ui-replication/run-shots-s8b4-b42.sh`（设置页 → 数据组 → 备份题库 → 恢复）。
  - 应用实际写出的备份 `shots/s8b4/quiz-master2-backup-app.json`（10,514 字节）：12 张表齐全（`subjects 3 / questions 9 / folders 9 / tags 3 / exams 3 / knowledge_points 8 / cause_records 7 / collect_tasks 0 / review_state 0 / review_history 0 / recent_tasks 1 / settings 16`），并有“备份已保存”提示（`13-backup-saved.png`）。
  - 恢复：选含标记行的备份 `shots/s8b4/quiz-master2-backup-s8b4.json` → 内联确认出现（`14-restore-confirm.png`，显示“将用备份文件……（9 道题）覆盖现在的题库（当前 9 道题）”）→ 点“确认恢复” → “已恢复备份”（`15-restored.png`）→ 查库：`questions=9`，`collect_tasks=1（ct-marker）`，`review_state=1`，`review_history=1`，`recent_tasks=marker-task`——4 张表数据都回来了。
- 环境限制（与应用无关）：本机 zenity 4.0.1 精简版不支持 `--save`、`--file-filter`、`--directory`，file_picker 调了就直接报错退出（`11-backup-no-dialog-zenity-limitation.png` 是点了备份题库后无任何对话框的截图）。验证用的垫片 `/tmp/qm2-bin/zenity`（脚本每次跑都重建）只按参数返回固定选择，让应用本身的流程完整跑通；Win11 上是原生对话框，不受影响。

## B4.3 数据库位置切换迁移旧库

### 做了什么

- `AppDatabase.migrateToDirectory(dir, {overwrite})`（`lib/data/database.dart`，返回 `DbMigrationOutcome`）：
  - 顺序：先关当前库 → 复制旧库文件 → 写标记文件（标记是位置的唯一依据；写标记前失败，旧库与旧标记都原地不动）。
  - 复制成功后把 `databaseLocation` 写进新库（新库已存在，打开不会触发建库播种；写失败也不影响，标记文件才是依据）。
  - 只复制库文件本身（`quiz-master2.db`，`-wal`/`-shm` 若存在也一并复制）；切片图目前不落盘（占位色块），没有要迁的文件。
  - 复制中途失败时只删本次新建的目标文件，不动覆盖模式下原先就有的目标文件。
  - 结果：`migrated`（已复制）/ `noSourceDb`（旧位置无库，只写标记）/ `targetExists`（新位置已有库且未指定覆盖，什么都没动）/ `failed`（复制或写标记失败）/ `sameLocation`。
- `copyDatabaseFileTo`（静态，纯文件操作，可单测）与 `databaseExistsAt`。
- 设置页 `_changeDbLocation`：新位置已有库文件时先弹对话框（三选一）：**覆盖**（用当前题库替换新位置的库）/ **保留现有库**（直接用新位置原来的题库，当前题库留在原位置不动——走旧的 `setCustomDataDirectory`，只写标记）/ **取消**。新位置没有库时直接迁移。迁移失败提示“迁移失败，仍用原来的题库”。
- 提示语修正：迁移后数据库其实已经在新位置了（设置页路径栏立即显示新路径），旧提示“重启前还是用现在这个位置”是错的。新增 `_dbMigrated` 区分：迁了库显示“新位置已保存：题库已迁过去，重启后彻底生效。”；“保留现有库”仍走旧提示语。

### 验证

- 单测 `test/s8b4_backup_migration_test.dart`（B4.3 部分 5 个）：复制到新位置（文件在、内容一致）、目标已有库且不覆盖（返回 false、目标原文件不动）、指定覆盖（内容被替换）、旧库不存在（返回 true、无文件产生）、`databaseExistsAt`。整机迁移（关库 + 写标记）不进单测（会改真实应用的库位置），见下真机验证。
- 真机：脚本 `docs/ui-replication/run-shots-s8b4-b43.sh`（垫片 zenity 返回目录选择；`改位置`按钮 y 随路径换行变：一行路径约 512，两行约 530，脚本按阶段传参）。

| 步骤 | 操作 | 结果 | 截图 |
|---|---|---|---|
| 迁到空目录 | 选 `/tmp/qm2-s8b4-newloc`（空）→ 改位置 | 提示“已把题库迁移到新位置，重启后生效”；新位置有库文件（94,208 字节），`questions=9`、`collect_tasks=1`、`recent_tasks=marker-task`，标记文件内容为新位置 | `16-migrated-snack.png` |
| 重启 | 重进应用 | 设置页数据库位置显示 `/tmp/qm2-s8b4-newloc/quiz-master2.db` | `17-new-location.png` |
| 已有库 → 保留 | 选 `/tmp/qm2-s8b4-keep`（已有库，`recent_tasks=keep-marker`）→ 改位置 | 弹对话框“这个位置已经有题库了”（覆盖/保留现有库/取消）；点“保留现有库”→ 提示“已切换到新位置原来的题库，重启后生效”，标记文件改为 keep；原 newloc 库原封不动（`recent_tasks=marker-task`，9 道题） | `18-target-exists-dialog.png`、`19-kept-snack.png` |
| 重启 | 重进应用 | 设置页显示 `/tmp/qm2-s8b4-keep/quiz-master2.db` | `20-kept-location.png` |
| 已有库 → 覆盖 | 选默认目录（已有库）→ 改位置 → 点“覆盖” | 提示“已把题库迁移到新位置，重启后生效”；标记文件回到默认目录；默认位置库 `questions=9`、`collect_tasks=1`、`review_state=1`、`review_history=1`、`recent_tasks=keep-marker`、到期错因 1 个 | `21-target-exists-dialog-default.png`、`22-overwrote-snack.png` |
| 切回来 | 重进应用 | 首页正常：3 道要复习、数学/英语/政治三科、深色；“继续上次”显示 `数学「keep-marker」`（迁回来的数据） | `23-back-to-default.png` |

## 改动文件

- `lib/services/recheck_reminder.dart`（新增）：提醒判定纯函数。
- `lib/app.dart`：启动后判断一次复查提醒、弹对话框。
- `lib/data/database.dart`：`backupTables` + 导出/恢复可单测版、提醒日期 key、迁移（`migrateToDirectory` / `copyDatabaseFileTo` / `databaseExistsAt` / `DbMigrationOutcome`）。
- `lib/data/repository.dart`：`importBackupJson`、`recheckDueCauseCount`、提醒日期、迁移透传。
- `lib/modules/settings/settings_page.dart`：恢复走 `importBackupJson`、备份落盘修旧 bug、改位置走迁移 + 已有库对话框 + 提示语区分。
- `test/s8b4_reminder_test.dart`（新增，11 个）、`test/s8b4_backup_migration_test.dart`（新增，9 个）。
- `docs/ui-replication/S8B4-REPORT.md`（本报告）、`run-shots-s8b4-b41.sh` / `run-shots-s8b4-b42.sh` / `run-shots-s8b4-b43.sh`、`shots/s8b4/`（截图 22 张 + 两份备份 JSON）。

## 未做的事 / 遗留

- B5、 B8 未动（任务要求：B5 无代码改动、B8 已确认无误）；B6 及以后未动。
- 备份/恢复/改位置在 Linux 上依赖 zenity，本机精简版 zenity 不支持 file_picker 要用的参数——已用垫片绕过验证；Win11 原生对话框不受影响（file_picker 在 Windows 上不走 zenity）。
- 迁移只复制库文件：切片图目前不落盘，无需迁移；将来真实切片落盘后，迁移需一并处理切片目录（届时再定，不在本次范围）。
- 迁移失败回滚只覆盖复制与写标记两步：若复制成功但写标记失败返回 `failed`，新位置会留下一个已复制的库文件副本（旧库不受影响，标记仍指旧位置，应用继续用旧库）；下次再迁会因目标已有库而弹对话框。未做自动清理残留副本。
