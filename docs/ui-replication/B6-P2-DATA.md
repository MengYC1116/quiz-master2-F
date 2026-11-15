# Batch 6 P2 · 数据层报告（B6-P2-DATA）

- 日期：2026-11-15
- 工作树：`~/workspace/quiz-master2-UI`，分支 `ui-replication`
- 执行员：C-data（P2 数据层）
- 范围：SELF-REVIEW-2 的 SR2-14～SR2-19、SR2-58、SR2-59、SR2-65～SR2-70
- 原则：只改指派文件（`lib/data/db_questions.dart`、`db_catalog.dart`、`db_backup.dart`、`db_collect.dart`、`lib/services/zip_archive.dart`、`test/b5_p2_data_test.dart`、`test/b5_p0_1_orphan_test.dart`、`docs/ui-replication/B5-P2-DATA.md` 的 P2-6 一句）；`db_schema.dart` 未动（SR2-15 选了事务方案，未选 UNIQUE 方案）；不 commit、不 push、不碰演示库。

## 逐项结果

| 项 | 结果 | 改动 |
|---|---|---|
| SR2-14 全行 REPLACE 快照覆盖库内新值 | ✅ 已修 + 测试（3 例） | `db_questions.dart`：`setReviewJoinedIntoImpl` 改为事务内按列 UPDATE `review_joined`（行不存在时才整行 INSERT）；`upsertQuestionIntoImpl` 改为 UPDATE-first，UPDATE 列里不含 `review_count`（不存在时才整行 INSERT）；`upsertCauseRecord` 改为只 UPDATE `remedy_history` 列（不存在时才整行 INSERT）。`review_count` 从此只由 `recordSelfCheckIntoImpl` 的 SQL `+1` 改 |
| SR2-15 `upsertFolder` 判重与插入非原子 | ✅ 已修 + 测试（1 例） | `db_catalog.dart`：选事务方案（未改 DDL）。判重 + 插入包进同一 `db.transaction`；`folderNameExistsInSubjectFromImpl` 参数由 `Database` 放宽为 `DatabaseExecutor`（与 `_seedCauseRecordsFor` 同一口径），以便把事务句柄传进来 |
| SR2-16 备份校验放过空串主键 | ✅ 已修 + 测试（1 例，3 个子情形） | `db_backup.dart`：`_validateBackupRow` 里 TEXT 主键（`id`/`key`）与必填 String 列要求 `isNotEmpty`，空串按“损坏的备份”拒绝 |
| SR2-17 `readZip` 不拒重名条目 | ✅ 已修 + 测试（2 例） | `zip_archive.dart`：`readZip` 按名判重，重名文件条目抛 `ZipFormatException`（`backup.json` 重名是例外，仍放行、恢复取最后一个）；恢复入口因此在解包阶段即报“已损坏”，不再走到进位循环误报“文件写不进去” |
| SR2-18 `confirmSplitInto` 框回填仍用 REPLACE 且不去重 | ✅ 已修 + 测试（1 例，与 SR2-70 合并） | `db_collect.dart`：框回填复用保留任务草稿的 `seenIds` 口径（重复 id 直接跳过、保留第一个）；另修正 `replaceQuestionBoxesAndSliceIntoImpl` 的过期注释（SR2-3 已改成临时文件 + 事务成功后 rename，该注释已按新口径重写；已核实详情页 `question_detail_page.dart:359-417` 的临时文件 + rename 实现已落地） |
| SR2-19 恢复估算不含 staging 临时占用 | ✅ 已修 + 测试（见 SR2-58/65 的 2 例） | `db_backup.dart`：估算改用峰值口径 `usedBytes + incomingBytes` 与 2GB 上限比较；将被覆盖的文件不再抵扣估算；超限文案改为“恢复时峰值占用会超过 2GB 存储上限（现有 X，恢复中峰值约 Y）” |
| SR2-58 2GB 边界恰好等于上限未测 | ✅ 已补（与 SR2-65 合并写） | `test/b5_p2_data_test.dart`：现有占用 2GB−200 字节 + 两条 100 字节文件条目，峰值恰好 2GB，放行 |
| SR2-59 P2-2 用例名与断言矛盾 | ✅ 已改名 | 用例名改为“演示题的框清掉、任务指向置空；断点队列去掉演示条目、其余不动”；断言本身正确，未动 |
| SR2-65 zip 用例无文件条目 | ✅ 已补（与 SR2-58 合并写） | 两例：恰好 2GB 用例用两条文件条目覆盖 incoming 累加；峰值超限用例覆盖“将被覆盖的文件不抵扣峰值”（旧口径恢复后占用 < 2GB 本会放行，新口径峰值 2GB+100 拒绝） |
| SR2-66 SR-P2-6 零测试覆盖 + B5 报告“已测”不实 | ✅ 已补（4 例）+ 报告已更正 | `test/b5_p2_data_test.dart` 新增 SR2-66 组（staging 严格匹配 + 三档文案）；`B5-P2-DATA.md` 的 SR-P2-6 行与测试覆盖句已改成与实际一致（见“与规定修法有出入处”） |
| SR2-67 SR-P2-16 三分支无用例 | ✅ 已补（3 例） | `'unsure' 不写库（含无行时返回传入值、有行时返回库内值）`、`'未解决' solvedCount 清 0`、`无行时按传入值写库` |
| SR2-68 `_`/`%` 转义分支无用例 | ✅ 已补（2 例） | 含 `_` 的任务 id（`or_ig` vs `orXig`，转义后目录正常删掉）；含 `%` 的任务 id（安全字符校验不通过，目录保留、不误删） |
| SR2-69 旋转烘焙页图未覆盖 | ✅ 已补（1 例） | `test/b5_p0_1_orphan_test.dart`：`pages/page-1-r90.png` 与 `page-2-r270.png` 不在孤儿列表里 |
| SR2-70 碰撞后 REPLACE 静默覆盖无用例 | ✅ 已补（与 SR2-18 合并写，1 例） | 同一题内两个同 id 不同坐标的框确认后只剩 1 行、保留第一个的坐标（旧写法会静默覆盖成第二个） |

## 改动文件与行（以当前工作树为准）

- `lib/data/db_questions.dart`：`setReviewJoinedIntoImpl`（约 :29-60，按列 UPDATE）；`upsertQuestionIntoImpl`（约 :180-200，UPDATE-first 去 `review_count`）；`upsertCauseRecord`（约 :400-425，只改 `remedy_history`）
- `lib/data/db_catalog.dart`：`folderNameExistsInSubjectFromImpl`（参数放宽为 `DatabaseExecutor`）；`upsertFolder`（判重 + 插入同一事务）
- `lib/data/db_backup.dart`：`_validateBackupRow`（空串拒绝）；`importBackupZipIntoImpl`（峰值估算 + 文案，含步骤注释）
- `lib/data/db_collect.dart`：`confirmSplitIntoImpl`（框回填 `seenBoxIds` 去重）；`replaceQuestionBoxesAndSliceIntoImpl` 注释（SR2-3 新口径）
- `lib/services/zip_archive.dart`：`readZip`（`seenNames` 判重，`backup.json` 除外）及 doc 注释
- `test/b5_p2_data_test.dart`：36 项 → 56 项（新增 19 项，见上表；另 SR2-59 改名 1 处；GAPS 的 SR2-27 补 1 项。成文时为 55 项，SR2-27 在后才加）
- `test/b5_p0_1_orphan_test.dart`：3 项 → 4 项（新增 SR2-69 1 项）
- `docs/ui-replication/B5-P2-DATA.md`：SR-P2-6 行与测试覆盖句更正（见下）

## 与规定修法有出入处（均写明原因）

1. **SR2-14：`toggleFavorite` / `archive` / `save` 未改成各自的按列 UPDATE 方法。** 任务列出的文件不含 `repository.dart`（`toggleFavorite` / `archive` / `save` / `saveRemedy` 都经它转发），故未在仓库层加 `setQuestionFavorite` / `setQuestionArchived` / `updateCauseRemedy` 这类专用方法；改为在三者共同的 choke 点修：`upsertQuestionIntoImpl`（UPDATE-first 且 UPDATE 列永不含 `review_count`）与 `upsertCauseRecord`（只改 `remedy_history`）。效果等价于规定修法要防的现象：持旧快照调这三路，库内 `review_count` / 自查改掉的状态、计数、复查日不再被打回。回归测试钉住的正是这两条路径（`setReviewJoinedInto` 旧快照、`upsertQuestionInto` 旧快照、`upsertCauseRecord` 旧快照各 1 例）。若协调员认为仓库层仍应补专用按列方法，需另立一项改 `repository.dart`。
2. **SR2-14：`upsertCauseRecord` 只改 `remedy_history`，是按“唯一生产调用方”定的语义。** 核实过：`saveCauseRecord` 在 `lib/` 与 `test/` 里无任何调用方；`saveRemedy` 只改 `remedy_history`；状态 / 计数 / 复查日的唯一写路径是 `recordSelfCheckIntoImpl`（事务内先读库内行再重算）。此语义已写进方法注释；若将来有调用方想经 `upsertCauseRecord` 改状态，须走 `recordSelfCheckTxn`，不要直接调它。
3. **SR2-15：未选 UNIQUE 约束方案。** 按任务推荐选了事务方案（改动最小）；`folders` 表 DDL 未动，`db_schema.dart` 无改动。
4. **SR2-16：`settings.value` 空串不拒绝。** 它是通用值列，空串是合法设置值（如清空问候语），只要求它是 String；其余必填 String 列（`id`/`key`/`name`/`title`/`subject_id`/`chapter`/`cause`/`question_id`/`result`/`kind`/`file_name` 等）一律要求非空。已写进代码注释。
5. **SR2-19 + SR2-65：“replaced 抵扣”分支的覆盖方式。** SR2-19 修法把估算改为峰值口径后，将被覆盖的文件不再参与估算，故“抵扣”本身已不存在；SR2-65 的该分支改用反向用例覆盖：现有 2GB−100 字节（含 500 字节待覆盖文件）+ 200 字节新文件，旧口径恢复后占用 < 2GB 本会放行，新口径峰值 2GB+100 拒绝，且原文件保持 500 字节不动。该用例同时证明峰值口径下抵扣不生效。
6. **SR2-66 第二档（`DatabaseException` →“备份数据有问题”）的覆盖方式。** `importBackupZipIntoImpl` catch 里的 `DatabaseException` 分支本身几乎不可直接到达——`importBackupJsonInto` 内部已先把插库的 `DatabaseException` 包成同文案的 `BackupRestoreException`，走到 zip 层 catch 时已是第一档原样抛。测试用 `BEFORE INSERT ON questions` 触发器注入数据库失败，断言端到端文案是“备份数据有问题”而不是“文件写不进去”，覆盖的是用户可见的文案分流；zip 层 catch 里的 `DatabaseException` 分支作为防御代码保留，未单独立可到达的用例。
7. **B5-P2-DATA.md 的更正写法。** 按任务要求：SR-P2-6 行改为“✅ 已修；测试 Batch 6 已补（SR2-66）”，并加粗注明 Batch 5 原文“已修 + 测试”与事实不符、此前“已测”的说法作废；测试覆盖句的 P2-6 处加了同样的更正括号。未改该文档其它历史数字（如 Batch 5 的“36 项”仍是当时的记录，Batch 6 的 55 项见本报告）。

## 测试证据

- `flutter analyze`（`lib/data/db_questions.dart`、`db_catalog.dart`、`db_backup.dart`、`db_collect.dart`、`lib/services/zip_archive.dart`、`test/b5_p2_data_test.dart`、`test/b5_p0_1_orphan_test.dart`，7 个文件）：**0 问题**。
- `flutter test`：**未跑通——环境失败，非代码问题**。按任务要求只尝试跑一次（`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux flutter test --concurrency=1 test/b5_p2_data_test.dart`）：在 `pdfium_dart` 原生资源构建处失败，`No compiler configured on host 'linux_x64'`（clang/ninja 丢失，与任务描述一致）。未自行修复工具链（未下载/安装/跑恢复脚本）。**全部 19 个新增用例 + 1 处改名均未经测试运行验证**，须等工具链恢复后由总协调补跑：`test/b5_p2_data_test.dart`（55 项）与 `test/b5_p0_1_orphan_test.dart`（4 项），并复核全量回归。
- 新增用例的正确性目前只以代码走读 + `flutter analyze` 保证；其中两处请补跑时重点看：(a) SR2-15 并发用例依赖 sqflite 事务串行化（两路 `upsertFolder` 一路成功、一路抛“已经有了”）；(b) SR2-66 第三档用例依赖 `slices` 在盘上是文件不是目录时 `dest.parent.create(recursive: true)` 抛 `FileSystemException`。

## 遗留问题

1. **测试未跑**（见上）：工具链恢复后须补跑本批两个测试文件 + 全量回归；演示库 md5 未核查（本批未动演示库，但未跑测试亦未验证）。
2. **SR2-14 的仓库层专用按列方法未建**（见出入处第 1 条）：`toggleFavorite` / `archive` / `save` 仍走通用 `upsertQuestion`，只是通用路径已不再写 `review_count`；若将来通用 `upsertQuestion` 被其它调用方用于“以快照为准”的整行覆盖，仍有同类风险，需另立一项。
3. **SR2-16 空串拒绝的波及面**：全仓 grep 未发现既有备份夹具在必填 String 列用空串（`testQuestion()` 等均为非空），但 `flutter test` 未跑，`p1_schema_backup_test.dart` / `s8b4_backup_migration_test.dart` 等既有备份用例须在补跑时确认无回归；若某处合法备份含空串必填列（如空标题题），需回头收窄口径。
4. **SR2-19 峰值口径偏保守**：恢复后占用 < 2GB、但恢复中峰值 > 2GB 的备份现在会被拒绝（正是 SR2-65 反向用例锁定的行为）；若 Meng 认为“最终占用不超即可、峰值可超”，需改回恢复后口径 + staging 前再判磁盘剩余空间（Dart 无直接查剩余空间的 API，需另议实现）。
