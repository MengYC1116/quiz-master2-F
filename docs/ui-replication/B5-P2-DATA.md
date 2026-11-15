# Batch 5 第五阶段 P2 · 数据层报告（B5-P2-DATA）

- 日期：2026-11-15
- 工作树：`~/workspace/quiz-master2-UI`，分支 `ui-replication`
- 范围：SR-P2-1/2/3/4/5/6/7/8/9/10/11/12/13/14/15/16/17/22/36/68（数据层部分）
- 原则：只改 `lib/data/*`（`database.dart`、`db_*.dart`、`repository.dart`、`demo_data.dart`）与 `lib/services/zip_archive.dart`（SR-P2-68 的文件本身就在 services，任务明确指派）；不 commit、不 push、不碰演示库。

## 逐项结果

| 项 | 结果 | 改动 |
|---|---|---|
| SR-P2-1 删学科漏清草稿框 | ✅ 已修 + 测试 | `db_catalog.dart`：`deleteSubjectFromImpl` 事务内先按该科任务 id 删 `question_boxes`（草稿 + 其 layer-2 子框都带 `collect_task_id`），再删任务行 |
| SR-P2-2 清演示绕开删题事务 | ✅ 已修 + 测试（另改 1 处既有测试） | `db_settings.dart`：`clearDemoDataFromImpl` 改走 `_deleteQuestionTxn`（框、解决记录、自查历史、任务指向、复习队列一并清）；`review_state` 不再整行删（演示题只从队列摘掉），`recent_tasks` 不动（旧写法会抹掉非演示的最近任务）。`test/p0_hardening_test.dart` 对应测试按新口径更新 |
| SR-P2-3 详情重框先写盘残留孤儿切片 | ⚠️ 数据层无可改处，转交详情页工人 | 见“需转交”第 1 条 |
| SR-P2-4 备份校验缺口 | ✅ 已修 + 测试（另改 2 处既有测试） | `db_backup.dart`：`validateBackupDataImpl` 改为 13 张表键缺失即拒绝（不再按空表静默清空）、主键 null 拒绝（TEXT 主键须非空字符串；整数主键出现时须非空整数；`cause_records`/`review_history` 自增 id 缺失允许）、每表必填列 + 类型校验（`_requiredBackupColumns`）；`importBackupJsonIntoImpl` 把插库残余 `DatabaseException` 统一包成 `BackupRestoreException`（“备份数据有问题”）。`test/p1_schema_backup_test.dart` 与 `test/s8b4_backup_migration_test.dart` 里两处钉住旧行为（缺表按空清空）的测试按新口径更新为“拒绝恢复” |
| SR-P2-5 备份恢复绕过 2GB 上限 | ✅ 已修 + 测试 | `db_backup.dart`：`importBackupZipIntoImpl` 在文件进位前估算（现有占用 − 将被覆盖的文件 + 解压后总字节），超 2GB 拒绝整个恢复，文案含现有/恢复后字节数；`_maxRestoreBytes` 常量与 `ImportService.maxStorageBytes` 同值（database.dart 不能 import import_service，会循环依赖，故另列常量并注明）。JSON 恢复不产生新文件，不适用此检查。`readZip` 的 4GB 上限保持不变（见 SR-P2-68） |
| SR-P2-6 zip 恢复文案误导 + staging 清理 | ✅ 已修；测试 Batch 6 已补（SR2-66） | `db_backup.dart`：catch 分三档——`BackupRestoreException` 原样抛、`DatabaseException` →“恢复失败：备份数据有问题，原题库没动”、其余 IO 异常 →“恢复失败：文件写不进去，原题库没动”；旧 staging 清理改走严格匹配 `_isRestoreStagingDir`（`.restore-staging-<纯数字时间戳>` 才删，与迁移的 B2-5d 同口径）。**更正**：Batch 5 报告原文写“已修 + 测试”与事实不符——Batch 5 时 P2-6 无任何用例（见 SR2-66）；测试于 Batch 6 补上（`test/b5_p2_data_test.dart` 新增 SR2-66 组：staging 严格匹配 + 三档文案各一例），此前“已测”的说法作废 |
| SR-P2-7 setCustomDataDirectory | ✅ 已修 + 测试 | `db_paths.dart`：标记目录改为 `testMarkerDirectory ?? _defaultDataDirectoryPath()`；目录先校验（空串/不存在/不是目录拒绝）；顺序改为先写设置、后写标记，标记写失败时把设置回滚到旧值（无旧值则删行）再抛原错 |
| SR-P2-8 setReviewJoined/syncCauseRecords 多步写 | ✅ 已修 + 测试 | 新增 `setReviewJoinedIntoImpl` / `syncCauseRecordsIntoImpl`（题行 + 错因记录同事务；`_seedCauseRecordsFor` 参数由 `Database` 放宽为 `DatabaseExecutor`，事务内复用）；`repository.setReviewJoined` / `syncCauseRecords` 改走事务版（对外签名不变）；空错因加入仍返回 false |
| SR-P2-9 saveSettings 逐条写 | ✅ 已修 + 测试 | 新增 `saveSettingsIntoImpl`（一个事务批量 replace）；实例 `saveSettings` 改走它 |
| SR-P2-10 confirmSplitInto 用 REPLACE 静默覆盖 | ✅ 已修 + 测试 | `db_collect.dart`：事务内先查同 id 题目/拆分任务是否存在（存在抛 `StateError`“请勿重复确认”），插入改 `ConflictAlgorithm.fail`；保留任务同 id 先删后插是刻意设计，不在此列；框回填仍用 REPLACE（id 唯一，见 SR-P2-12） |
| SR-P2-11 deleteLegacyDatabaseIfPresent 顺序 | ✅ 已修 + 测试 | `db_schema.dart`：先删 `-wal`/`-shm`（失败静默跳过），再删主库；只有主库删失败才抛错重试（此时老库还在，重试才有意义）。附属删失败分支是防 Windows 文件锁定的防御代码，Linux 单测无法直接模拟（见“遗留问题”） |
| SR-P2-12 newBoxId 只有 32 位熵 | ✅ 已修 + 测试 | `db_paths.dart`：随机段 8 位 → 16 位十六进制（64 位熵），格式仍为 `box-<scope>-p<page>-<16hex>`，不引入 uuid 包 |
| SR-P2-13 demoQuestions() 死代码 + 4 道题状态矛盾 | ✅ 已修（删除函数） | `demo_data.dart`：删除 `demoQuestions()`（全仓无任何调用方，仅定义；其中 4 道题 `reviewJoined: true` 却 `isOrganized: false`，违反模型）。`demoExams()` / `demoKnowledgePoints()` 仍在 `_seed` 里用，保留。无单独测试，以编译 + 全仓 grep（仅剩注释提及）为证 |
| SR-P2-14 saveDraftBoxesInto 旋转角静默丢失、缺页键保留旧草稿 | ✅ 已修 + 测试 | `db_collect.dart`：旋转角 `update` 影响 0 行（任务行不存在）时抛 `StateError` 回滚，不再让框写进去、旋转角丢了；注释写明调用方契约——被清空的页必须以空列表键传进来，缺页键的旧草稿会被保留 |
| SR-P2-15 _deleteTaskDirIfUnreferenced 不查 collect_tasks.source_path | ✅ 已修 + 测试 | `db_collect.dart`：补查 `collect_tasks.source_path LIKE 'imports/<taskId>/%'`；LIKE 里的 `_`/`%`/`\` 先转义（新增 `_likeEscape`，与 `_deleteFolderTxn` 共用，`ESCAPE '\'`），含 `_` 的任务 id 不误匹配 |
| SR-P2-16 recordSelfCheck 按快照算新值 | ✅ 已修 + 测试 | `db_questions.dart` + `repository.dart`：`recordSelfCheckIntoImpl` 在事务内先读库内当前行再重算（`solvedCount` 在当前值上递增；复查通过不加计数；`remedyHistory`/`joinedAt` 以库内值为准；无行时才按传入值写），返回实际写库的记录；`recordSelfCheckTxn` 与 `repository.recordSelfCheck` 同步改（返回写库值；`unsure` 不写库） |
| SR-P2-17 _deleteFolderTxn 每层递归全表读题 | ✅ 已修 + 测试 | `db_catalog.dart`：每层按 `folder_ids LIKE '%"id"%'` 在 SQL 层粗筛（`"` 定界防 `f1`/`f10` 子串误筛，`_likeEscape` 防通配符），再内存按 `folderIds` 精筛，只解码命中行 |
| SR-P2-22 确认拆题中途失败留孤儿切片/烘焙页图；保留任务重建两步写 | ⚠️ 数据层部分早已完成（P1-2），剩余转交收集页工人 | 保留任务重建已在 P1-2 收进 `confirmSplitInto` 同一事务（`retainedTask` 参数，`collect_page.dart:571-620` 已在用）；剩余“失败时删本次新建的切片/烘焙文件”在调用方，见“需转交”第 2 条 |
| SR-P2-36 文件夹同名判重改成整科 | ✅ 数据层已修 + 测试；页内三处预检转交错题本工人 | `db_catalog.dart`：新增 `folderNameExistsInSubjectFromImpl`（整科按名查，`excludeId` 排除自身）+ `AppDatabase.folderNameExistsInSubjectFrom` 静态转发 + 实例方法 + `repository.folderNameExistsInSubject` 透传；`upsertFolder` 增加整科同名把关（存在即抛 `StateError`“已经有了：同一学科下已有同名文件夹“…”，自己原地更新不触发）。页内新建/改名/移入三处预检与提示见“需转交”第 3 条 |
| SR-P2-68 readZip 不解析中央目录 | ✅ 已修 + 测试 | `lib/services/zip_archive.dart`：`readZip` 改走中央目录（EOCD 定位 → 逐项校验条目数/偏移/名/方法/尺寸；local header 只定位数据起点，名/方法与中央目录不一致即损坏；flag bit 3 的数据描述符按中央目录尺寸读，直接跳过；解压前用中央目录 `rawSize` 做上限预判；无文件条目（空 zip / 只含目录条目）抛错；ZIP64 与多盘明确拒绝）。`buildZip` 与测试的 `buildStoredZip` 产出的包均正常读回（回归测试覆盖） |

## 改动文件

- `lib/data/db_catalog.dart`：SR-P2-1、SR-P2-17、SR-P2-36、`_likeEscape`
- `lib/data/db_settings.dart`：SR-P2-2、SR-P2-9
- `lib/data/db_paths.dart`：SR-P2-7、SR-P2-12
- `lib/data/db_schema.dart`：SR-P2-11、`_seedCauseRecordsFor` 参数放宽为 `DatabaseExecutor`
- `lib/data/db_collect.dart`：SR-P2-10、SR-P2-14、SR-P2-15
- `lib/data/db_questions.dart`：SR-P2-8、SR-P2-16
- `lib/data/db_backup.dart`：SR-P2-4、SR-P2-5、SR-P2-6
- `lib/data/database.dart`：新增静态转发（`folderNameExistsInSubjectFrom`、`saveSettingsInto`、`setReviewJoinedInto`、`syncCauseRecordsInto`；`recordSelfCheckInto` 签名 + 返回值同步）
- `lib/data/repository.dart`：SR-P2-8、SR-P2-16（走事务版；对外签名不变）、`folderNameExistsInSubject` 透传
- `lib/data/demo_data.dart`：SR-P2-13 删除 `demoQuestions()`
- `lib/services/zip_archive.dart`：SR-P2-68
- `test/b5_p2_data_test.dart`（新增）、`test/p0_hardening_test.dart`、`test/p1_schema_backup_test.dart`、`test/s8b4_backup_migration_test.dart`（三处既有测试按新口径更新，见上表）

## 测试

- 新增 `test/b5_p2_data_test.dart`：36 项，全部通过（内存库 + 临时目录；P2-5 用稀疏文件模拟 2GB+1/1GB 占用，几乎不占真实磁盘）。
  - 覆盖：P2-1、P2-2、P2-4（缺表/主键 null/必填列缺失与类型错/插库包装）、P2-5（超限拒绝 + 1GB 对照放行）、P2-6（staging 严格匹配 + DB 失败文案）【更正：该覆盖是 Batch 6（SR2-66）补的，Batch 5 报告写“已测”时实际无用例，见上表 SR-P2-6 行】、P2-7（标记重定向/不存在拒绝/标记失败回滚设置）、P2-8（同事务建出/触发器失败回滚/空错因返回 false/同步删旧补新）、P2-9（触发器失败回滚/成功写全）、P2-10（重复题/重复拆分任务显式失败且旧数据不动）、P2-11（v1 全删/v2 不动/目录 -wal 时探针拒绝）、P2-12（16 位十六进制、1000 个不碰撞）、P2-14（任务不存在抛错回滚/空列表键清页 + 缺页键保留）、P2-15（拆分任务引用时目录保留/无人引用时删除）、P2-16（同一旧快照两次自查计 +2/复查不加计数）、P2-17（含 `_` 的文件夹 id 不误筛）、P2-36（同科跨层拒绝/跨科放行/自更新放行/改名撞名拒绝/预检 helper）、P2-68（数据描述符 stored+deflate/纯目录包抛错/中央本地名不一致抛错/超大单条目解压前预判/空 zip 抛错）。
- 针对性回归（`flutter test --concurrency=1`，并行跑测试会因 1.5 CPU 争用假死，见遗留问题）：
  - `test/b5_p2_data_test.dart`：36/36
  - `test/p0_hardening_test.dart` + `test/p1_schema_backup_test.dart` + `test/s8b4_backup_migration_test.dart` + `test/p3_backup_migration_test.dart`：66/66
  - `test/p2_main_chain_test.dart` + `test/b5_p1_256_test.dart` + `test/p2_json_fields_test.dart` + `test/b2_leftover_data_test.dart` + `test/b3_p01_path_safety_test.dart` + `test/collect_page_test.dart`：119 通过，2 失败——均为 `collect_page_test.dart` P1-2 组的无框警告 widget 测试，原因是并行收集工人在 `collect_page.dart` 里已落地 SR-P2-25 收窄（只对打开过修框或已有草稿框的任务显示警告），旧测试仍断言“从未打开的任务也警告”；与本批数据层改动无关（该测试用 FakeRepo，不走真实数据层），见“需转交”第 4 条
  - `test/review_page_test.dart` + `test/detail_page_test.dart` + `test/organize_page_test.dart` + `test/s8b3_startup_test.dart`：94/94
- `flutter analyze`：0 error；7 个 info/warning，无一在我改的文件里（`wrongbook_list.dart:484` 1 个 info；并行工人新建的 `test/b5_p2_collect_test.dart` 3 个、`test/b5_p2_services_test.dart` 2 个——均非本批数据层文件）。
- 演示库 md5 未变：`8f7f9c64405dc6e484ac2bf8e5e1a807`。

## 遗留问题

1. SR-P2-11 附属删失败不抛错的分支无法在 Linux 单测里直接验证：`-wal` 是目录时，SQLite 只读探针本身就打不开库（error 14），按保守口径拒绝删除、文件原样保留（已立测试锁定该行为）；该分支是防 Windows 文件锁定的防御代码，需 Win11 真机复核。
2. 并行跑测试时 1.5 CPU 争用会导致 `flutter test` 长时间零输出假死（本次一批 4 文件曾 13 分钟无输出，改 `--concurrency=1` 后 25 秒跑完 66 项；另注意勿凭 PID 猜测归属——并行工人的进程与本批同名，曾误查到服务工人的 `b5_p2_services_test.dart` 进程）。
3. SR-P2-5 的 2GB 估算不含数据库文件本身（与 `ImportService.storageUsageBytes` 的 imports/+slices/ 口径一致）；`readZip` 的 4GB 解压上限保持不变，zip 炸弹的内存 bound 仍是 4GB（SR-P2-68 的 `rawSize` 预判现在在解压前执行，不再先占满内存再触发）。

## 需转交其他工人的改动说明

1. **SR-P2-3 → 详情页工人**：`lib/modules/detail/question_detail_page.dart:347-366`（`_reworkBoxes` 附近）：切片文件在 `replaceQuestionBoxesAndSlice` 事务前写盘（`:354` `writeAsBytes`），事务失败（题不存在等）时新切片成孤儿文件。改动：把 `:366` 的 `await widget.repo.replaceQuestionBoxesAndSlice(...)` 包进 try/catch，失败时删刚写的切片文件（`sliceAbs`，`:348-353` 已算好），再按现有失败路径提示。数据层无可改处（文件写盘在 DB 事务之外）。
2. **SR-P2-22 剩余部分 → 收集页工人**：`lib/modules/collect/collect_page.dart:505-575`（`_confirmSplit` 的逐页裁剪循环）：切片 PNG 与旋转烘焙页图先写盘、再进事务，某页裁剪失败或事务失败时前面已写的文件留在 `slices/` / `imports/<id>/pages/` 里，无清理。改动：循环内记下本次确认新建的切片相对路径与烘焙页图相对路径清单（烘焙图只记 `rotation != 0` 时新建的 `bakedRel`，`:514-521`），`catch`（`:568-573`）里按清单删文件（只删本次新建的、不碰原任务页图），再提示 + `_load()`。保留任务重建两步写的问题已在 P1-2 由数据层解决，无需再改。
3. **SR-P2-36 页内三处 → 错题本工人**：`lib/modules/wrongbook/wrongbook_page.dart:563-580`（`_addFolder` 新建）、`:593-608`（`_saveRename` 改名）、`:685-730`（`_moveOneFolder` 移入）：三处把同名判重从“同层兄弟”改为整科——调新增的 `repo.folderNameExistsInSubject(subjectId, name, excludeId: 自身 id)`（新建时不传 `excludeId`），命中即提示“已经有了”并中止；`upsertFolder` 现为最后一道防线（命中抛 `StateError`，文案含“已经有了”），调用方须捕获并转 snack，不要当未知错误报。另外注意：`saveFolder` 的同名把关也会影响其它新建文件夹入口——`lib/modules/organize/organize_page.dart:478,2279`（新建文件夹）、`lib/modules/detail/question_detail_page.dart:610`（新建文件夹）、`lib/modules/subjects/subjects_page.dart:317`（新学科预置文件夹，名互不相同、不受影响）——组织/详情两处新建文件夹若撞名现在会抛 `StateError`，请各自的工人补同一预检或捕获提示。
4. **collect_page_test 2 项失败 → 收集页工人（或协调员裁决）**：`test/collect_page_test.dart` P1-2 组“无框警告：单张图没框 / 多页部分没框出警告，全框了不出”与“确认前报未框页数，确认后只拆有框页、未框页留任务可继续修框”——`collect_page.dart` 已按 SR-P2-25 收窄警告（`warnUnboxed` 门控，只对打开过修框或已有草稿框的任务显示，见 `:1159-1167` 与 `_hasAnyDraftBox`），旧测试仍按“从未打开也警告”断言。SR-P2-25 在自审里是“等 Meng 决定”项，如收窄已定，请收集工人同步更新这两处测试；如未定，请恢复旧行为。本批数据层未动该逻辑。
