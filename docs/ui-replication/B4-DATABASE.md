# B4-DATABASE：`lib/data/database.dart` 拆分报告

- 日期：2026-11-14
- 工人：数据库拆分（只拆 `database.dart`，不碰 `collect_page.dart` / `wrongbook_page.dart`）
- 原文件：`lib/data/database.dart` 约 119KB、3191 行 → **541 行**；新文件 10 个，共约 2964 行
- 结论：**纯重构完成，行为、公开接口、调用方、测试文件一律未改**

## 实现方式

`database.dart` 声明 `part 'db_*.dart';`，10 个新文件是同一库的 `part of 'database.dart'`，
共享库私有成员（`_db` / `_dbFuture` / `dbPathUsed` / 各 `_xxx` 顶层函数），不需要新 import。

- **公开静态方法**（56 个）：实现搬到 part 文件作顶层 `<name>Impl` 函数，
  `AppDatabase` 类内只留一行静态转发，签名与原声明逐字一致
  （`static <Ret> <name>(<params>) => <name>Impl(<args>);`，含具名参数原样转发）。
- **私有静态方法/字段**（32 个）：搬到 part 文件作同名顶层函数/变量，去掉 `static`，
  不改名、不改体。
- **实例方法**（67 个）：搬到 part 文件的 `extension … on AppDatabase` 里，调用方式不变。
- 移出类体后必须限定的引用已统一处理：类内静态成员调用改为 `AppDatabase.xxx`
  （如 `AppDatabase.dataDirectoryPath()` / `AppDatabase.encodeStringList()` /
  `AppDatabase.schemaVersion` / `AppDatabase.backupTables` 等）；
  文档注释里的 `[xxx]` 成员引用改为 `[AppDatabase.xxx]`。
- `database.dart` 保留：全部 import 与 `part` 声明；异常类
  `LegacyDatabaseException` / `BackupRestoreException`、`OrphanFile` /
  `OrphanScan`、`DbMigrationOutcome`；`AppDatabase` 类壳（`instance`、
  `schemaVersion` / `appVersion` / `backupTables` / `lastRouteKey` /
  `lastRecheckReminderKey` / `backupFailedKey` 常量、`_db` / `_dbFuture` /
  `dbPathUsed` 字段、`testDataDirectory` / `testMarkerDirectory`、
  测试钩子 `useDatabaseForTest` / `openForTest` / `resetForTest`、
  `db` getter、`_openDb`）+ 56 行静态转发。
- 删掉的只有 3 行类内 `// ---------- … ----------` 分隔注释（各文件头注释代替），
  其余代码（含注释）均为原文搬移。拆分由脚本按精确行号抽取
  （`/tmp/b4_split.py`，抽取前做覆盖率断言：原文件 3191 行除空白行与 3 行分隔注释外
  全部恰好落入一个成员切片），手写部分只有转发器（脚本按签名自动生成）与文件头注释。
- 最后对 11 个文件跑了 `dart format`（纯空白调整，9 个文件有改动；
  注意：拆分前原文件本身也不满足 `dart format --set-exit-if-changed`，
  属既有格式漂移，非本次引入）。

## 接口调整

**无。** 公开静态方法 56 个全部保留同名同签名转发；实例方法 67 个全部保留同名
extension 方法；常量、异常类、数据类不动；`repository.dart`、各页面、全部测试文件
**零改动**。未碰等 Meng 决定的两件事（.gitignore 是否忽略 38MB 模型文件；
红色无框警告范围是否收窄），未碰第三批遗留问题，未修 bug、未加功能。

## 新文件清单（行数为格式化后）

| 文件 | 行数 | 职责 |
|---|---|---|
| `lib/data/database.dart` | 541 | 入口：类壳 + 常量 + 测试钩子 + `db`/`_openDb` + 56 行静态转发 |
| `lib/data/db_paths.dart` | 137 | 路径解析与数据目录（`AppDatabasePaths`） |
| `lib/data/db_schema.dart` | 279 | 建库：`openAt` / 老库删除 / 13 张表 DDL / 播种 |
| `lib/data/db_storage.dart` | 345 | 数据目录迁移（`AppDatabaseStorage`） |
| `lib/data/db_codec.dart` | 250 | JSON 编解码与行映射 |
| `lib/data/db_questions.dart` | 284 | 题目 / 错因 / 复习状态（`AppDatabaseQuestions`） |
| `lib/data/db_catalog.dart` | 494 | 学科 / 文件夹 / 标签 / 试卷 / 知识点（`AppDatabaseCatalog`） |
| `lib/data/db_collect.dart` | 547 | 收集任务 / question_boxes / 文件级联删除（`AppDatabaseCollect`） |
| `lib/data/db_orphans.dart` | 123 | 孤儿文件扫描与清理（`AppDatabaseOrphans`） |
| `lib/data/db_settings.dart` | 178 | 设置 / 最近任务 / 演示数据（`AppDatabaseSettings`） |
| `lib/data/db_backup.dart` | 327 | 备份与恢复 JSON / zip（`AppDatabaseBackup`） |

## 拆分明细（行号为拆分前原文件行号，含上方文档注释；`[impl]`=公开静态→`<name>Impl`+转发，`[toplevel]`=私有静态→同名顶层函数，`[extension]`=实例方法→extension）

### `db_paths.dart`（9 顶层 + 1 extension）
- L115-127 `dataDirectoryPath` [impl]；L129-136 `setCustomDataDirectory` [extension]；
  L138-154 `resolveDataPath` [impl]；L156-176 `isAllowedDataRelativePath` [impl]；
  L178-182 `_safeTaskIdPattern` [toplevel]；L184-195 `newBoxId` [impl]；
  L244-246 `databaseExistsAt` [impl]；L587-606 `_defaultDataDirectoryPath` [toplevel]；
  L2219-2226 `_resolveInsideDir` [toplevel]；L2228-2242 `_toDataRelative` [toplevel]

### `db_schema.dart`（7 顶层）
- L628-642 `shouldFallbackAfterOpenFailure` [impl]；L675-702 `openAt` [impl]；
  L704-745 `deleteLegacyDatabaseIfPresent` [impl]；L747-750 `_onCreate` [toplevel]；
  L752-863 `createTables` [impl]；L865-884 `_seedCauseRecordsFor` [toplevel]；
  L886-935 `_seed` [toplevel]

### `db_storage.dart`（5 顶层 + 1 extension）
- L248-448 `migrateDataFiles` [impl]；L450-468 `rollbackMigrationFiles` [impl]；
  L470-491 `_deleteStaleMigrationStaging` [toplevel]；
  L493-497 `_deleteDirQuietly` [toplevel]；L499-509 `_deletePathQuietly` [toplevel]；
  L511-585 `migrateToDirectory` [extension]

### `db_codec.dart`（14 顶层；本任务新增文件，不在任务建议清单内——行映射被四处共用，单列一处收口）
- L937-948 `encodeStringList` [impl]；L950-960 `decodeStringList` [impl]；
  L962-962 `encodeRemedyList` [impl]；L964-965 `decodeRemedyList` [impl]；
  L967-969 `encodeQueue` [impl]；L971-988 `decodeQueue` [impl]；
  L990-1020 `_toRow` [toplevel]；L1022-1053 `_fromRow` [toplevel]；
  L1109-1129 `_causeFromRow` [toplevel]；L1156-1166 `_causeRecordToRow` [toplevel]；
  L1973-2011 `_collectTaskFromRow` [toplevel]；L2013-2029 `_collectTaskToRow` [toplevel]；
  L2365-2380 `_questionBoxToRow` [toplevel]；L2382-2399 `_questionBoxFromRow` [toplevel]

### `db_questions.dart`（7 顶层 + 16 extension）
- L1055-1055 `allQuestions` [extension]；L1057-1061 `allQuestionsFrom` [impl]；
  L1063-1073 `questionById` [extension]；L1075-1095 `reviewHistory` [extension]；
  L1097-1107 `addCauseCheckHistory` [extension]；L1131-1138 `allCauseRecords` [extension]；
  L1140-1149 `causeRecordsForQuestion` [extension]；L1151-1154 `ensureCauseRecords` [extension]；
  L1168-1176 `upsertCauseRecord` [extension]；L1178-1194 `recordSelfCheckTxn` [extension]；
  L1196-1219 `recordSelfCheckInto` [impl]；
  L1221-1228 `deleteCauseRecordsForQuestion` [extension]；
  L1230-1237 `deleteCauseRecord` [extension]；L1239-1250 `saveReviewState` [extension]；
  L1252-1264 `loadReviewState` [extension]；L1266-1269 `clearReviewState` [extension]；
  L1773-1777 `upsertQuestion` [extension]；L1779-1786 `upsertQuestionInto` [impl]；
  L1788-1792 `deleteQuestion` [extension]；L1794-1801 `deleteQuestionFrom` [impl]；
  L1803-1813 `_slicePathOf` [toplevel]；L1815-1832 `_removeFromReviewQueueTxn` [toplevel]；
  L1834-1878 `_deleteQuestionTxn` [toplevel]

### `db_catalog.dart`（13 顶层 + 20 extension）
- L1273-1290 `allSubjects` [extension]；L1292-1297 `_iconFor` [toplevel]；
  L1299-1321 `upsertSubject` [extension]；L1323-1327 `deleteSubject` [extension]；
  L1329-1383 `deleteSubjectFrom` [impl]；L1385-1406 `allFolders` [extension]；
  L1408-1418 `upsertFolder` [extension]；L1420-1427 `deleteFolder` [extension]；
  L1429-1446 `deleteFolderFrom` [impl]；L1448-1486 `_deleteFolderTxn` [toplevel]；
  L1488-1488 `allTags` [extension]；L1490-1495 `allTagsFrom` [impl]；
  L1497-1503 `insertTag` [extension]；L1505-1508 `renameTag` [extension]；
  L1510-1537 `renameTagFrom` [impl]；L1539-1542 `deleteTag` [extension]；
  L1544-1561 `deleteTagFrom` [impl]；L1563-1563 `allExams` [extension]；
  L1565-1579 `allExamsFrom` [impl]；L1581-1584 `insertExam` [extension]；
  L1586-1604 `insertExamInto` [impl]；L1606-1614 `renameExam` [extension]；
  L1616-1626 `deleteExam` [extension]；L1628-1629 `allKnowledgePoints` [extension]；
  L1631-1646 `allKnowledgePointsFrom` [impl]；L1648-1651 `insertKnowledgePoint` [extension]；
  L1653-1675 `insertKnowledgePointInto` [impl]；L1677-1685 `renameKnowledgePoint` [extension]；
  L1687-1690 `deleteKnowledgePoint` [extension]；L1692-1709 `deleteKnowledgePointFrom` [impl]；
  L1711-1726 `renameChapter` [extension]；L1728-1733 `deleteChapter` [extension]；
  L1735-1771 `deleteChapterFrom` [impl]

### `db_collect.dart`（17 顶层 + 9 extension）
- L2031-2032 `allCollectTasks` [extension]；L2034-2041 `allCollectTasksFrom` [impl]；
  L2043-2059 `upsertCollectTask` [extension]；L2061-2082 `upsertCollectTaskInto` [impl]；
  L2084-2097 `deleteCollectTask` [extension]；L2099-2143 `deleteCollectTaskFrom` [impl]；
  L2145-2166 `_deleteDataFileIfUnreferenced` [toplevel]；
  L2168-2187 `_isFileReferenced` [toplevel]；
  L2189-2217 `_deleteTaskDirIfUnreferenced` [toplevel]；
  L2401-2405 `insertQuestionBoxInto` [impl]；L2407-2418 `boxesForQuestionFrom` [impl]；
  L2420-2432 `boxesForTaskFrom` [impl]；L2434-2446 `boxesForTaskPageFrom` [impl]；
  L2448-2466 `boxesForPageImageFrom` [impl]；L2468-2523 `saveDraftBoxesInto` [impl]；
  L2525-2543 `saveDraftBoxes` [extension]；L2545-2547 `boxesForTask` [extension]；
  L2549-2551 `boxesForPageImage` [extension]；L2553-2564 `replaceQuestionBoxesInto` [impl]；
  L2566-2574 `replaceQuestionBoxes` [extension]；
  L2576-2606 `replaceQuestionBoxesAndSliceInto` [impl]；
  L2608-2626 `replaceQuestionBoxesAndSlice` [extension]；
  L2628-2650 `_replaceBoxesTxn` [toplevel]；L2652-2676 `_deleteBoxesForQuestionTxn` [toplevel]；
  L2678-2737 `confirmSplitInto` [impl]；L2739-2755 `confirmSplit` [extension]

### `db_orphans.dart`（3 顶层 + 2 extension）
- L2244-2273 `_referencedRelativePaths` [toplevel]；
  L2275-2303 `scanOrphanFilesFrom` [impl]；L2305-2353 `deleteOrphanFiles` [impl]；
  L2355-2356 `scanOrphans` [extension]；L2358-2361 `cleanOrphans` [extension]

### `db_settings.dart`（4 顶层 + 13 extension）
- L1880-1888 `normalizeRecentKind` [impl]；L1890-1900 `recentTask` [extension]；
  L1902-1915 `saveRecentTask` [extension]；L1917-1923 `clearDemoData` [extension]；
  L1925-1963 `clearDemoDataFrom` [impl]；L1965-1971 `demoQuestionCount` [extension]；
  L2759-2766 `loadSettings` [extension]；L2768-2774 `saveSetting` [extension]；
  L2776-2780 `saveSettings` [extension]；L2788-2798 `loadLastRoute` [extension]；
  L2800-2801 `saveLastRoute` [extension]；
  L2807-2817 `loadLastRecheckReminderDate` [extension]；
  L2819-2820 `saveLastRecheckReminderDate` [extension]；
  L2829-2839 `loadBackupFailedFrom` [impl]；L2841-2847 `saveBackupFailedInto` [impl]；
  L2849-2849 `loadBackupFailed` [extension]；L2851-2852 `saveBackupFailed` [extension]

### `db_backup.dart`（9 顶层 + 5 extension）
- L2873-2874 `exportBackupJson` [extension]；L2876-2894 `exportBackupJsonFrom` [impl]；
  L2896-2944 `validateBackupData` [impl]；L2946-2970 `_validateBackupRowPaths` [toplevel]；
  L2972-2979 `importBackupJson` [extension]；L2981-3014 `importBackupJsonInto` [impl]；
  L3016-3043 `exportBackupZipFrom` [impl]；L3045-3046 `exportBackupZip` [extension]；
  L3048-3054 `_readZipOrThrow` [toplevel]；L3056-3068 `_decodeBackupJson` [toplevel]；
  L3070-3084 `readBackupJsonFromZip` [impl]；L3086-3180 `importBackupZipInto` [impl]；
  L3182-3184 `importBackupZip` [extension]；L3186-3190 `importBackupZipFile` [extension]

### 留在 `database.dart` 的成员
- 构造器 `AppDatabase._()`、单例 `instance`；常量 `schemaVersion` / `appVersion` /
  `backupTables` / `lastRouteKey` / `lastRecheckReminderKey` / `backupFailedKey`；
  字段 `_db` / `_dbFuture` / `dbPathUsed`；`testDataDirectory` / `testMarkerDirectory`；
  `useDatabaseForTest` / `openForTest` / `resetForTest`；`db` getter；`_openDb`；
  以及 56 个静态转发（按 `db_paths` → `db_schema` → `db_storage` → `db_codec` →
  `db_questions` → `db_catalog` → `db_collect` → `db_orphans` → `db_settings` →
  `db_backup` 分组）。
- 注意：`backupTables` / `lastRouteKey` / `lastRecheckReminderKey` / `backupFailedKey`
  四个常量原在文件后部（设置/备份区），本次移到类首常量区集中声明，声明文本不变。

## 验证

- `flutter analyze lib/data/`：**No issues found**；`flutter analyze` 全量：**No issues found**。
  - 基线说明：开工时全量 analyze 有 54 个问题，全部在 `lib/modules/wrongbook/`
    （兄弟工人拆分进行中）；收工时全量 0 问题——wrongbook 的 54 个问题是兄弟工人
    同期修好的，本人未碰 wrongbook 任何文件。
- 相关测试（`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`，
  均分批跑，未跑全量 `flutter test`）：**507 个，全部通过**。
  - 第 1 批 85 个：`p0_hardening`、`p1_schema_backup`、`p3_backup_migration`、
    `p2_json_fields`、`p2_main_chain`
  - 第 2 批 63 个：`b3_p01_path_safety`、`s8b4_backup_migration`、`b2_leftover_data`、
    `b3_p11_layer2_downgrade`、`s8b3_startup`
  - 第 3 批 57 个：`s8b2_subject_sync`、`s8b2_subject_sync_supplement`、`s8b4_reminder`、
    `s8b6b7_leftover`、`p0b1_archived_counts`、`p0b1_settings_owner`、`p0b2_pagesize`、
    `b2_leftover_wrongbook_view`、`b2_win11bug_organize`、`import_service_pdf_fallback`
  - 第 4 批 224 个：`organize_page`、`review_page`、`subjects_page`、`settings_page`、
    `home_page`、`detail_page`、`report_page`、`collect_page`、`pdf_collect_page`、
    `pdf_render_service`
  - 第 5 批 78 个：`p0b1_subject_sync`、`b3_overlay_layer2`、`p05_image_pipeline`、
    `p05_image_pipeline_e2e`、`wrongbook_page`
  - `dart format` 之后复跑第 1 批中的 3 个文件（`p1_schema_backup`、`p3_backup_migration`、
    `p0_hardening`，60 个）再过一遍，全部通过。
  - 未跑的 10 个测试文件均为纯 UI / 服务单测（`app_shell`、`nav_hover_regression`、
    `p0b2_nav_palette`、`qm_banner`、`s8_chip_label`、`s8a5_section_scroll`、
    `theme_smoke`、`uikit`、`widgets_forward`、`yolo_onnx_service`），留给协调员全量跑。
- 演示库：开工前备份到 `~/workspace/demo-db-backup/quiz-master2.db.b4-db-start`；
  收工后 `~/.local/share/quiz-master2/quiz-master2.db` md5 仍为
  `8f7f9c64405dc6e484ac2bf8e5e1a807`（v1、9 题），未被测试改动。
- 公开 API 核对：用脚本比对拆分前后 `database.dart` 的成员签名——新增成员 0 个；
  56 个转发的签名（返回类型、名字、参数表）与原声明逐字一致，仅函数体由
  `async {…}` / `=> …` 改为 `=> <name>Impl(…);`。
- 未发现与其他工人文件的冲突；全程只改 `lib/data/database.dart`、只新增
  `lib/data/db_*.dart`，未改任何测试文件、调用方、collect/wrongbook 文件。
  未执行任何 git 命令。

## 改动文件

- 改：`lib/data/database.dart`（3191 行 → 541 行）
- 增：`lib/data/db_paths.dart`、`db_schema.dart`、`db_storage.dart`、`db_codec.dart`、
  `db_questions.dart`、`db_catalog.dart`、`db_collect.dart`、`db_orphans.dart`、
  `db_settings.dart`、`db_backup.dart`
- 报告：`docs/ui-replication/B4-DATABASE.md`（本文件）

## 遗留问题

- 无。本任务范围内无未决项；全量 `flutter test`（628 个）留给协调员最后统一跑。
- 拆前备份：`~/workspace/demo-db-backup/database-before-b4/database.dart.before-b4`
  （拆分前原文件全文，含 Batch 1/2/3 未提交改动）与
  `~/workspace/demo-db-backup/quiz-master2.db.b4-db-start`（演示库备份）；
  验收通过后可删。拆分脚本在 `/tmp/b4_split.py`（临时文件，虚拟机重启会清掉，
  如需复现拆分过程可找协调员索取——脚本本身不在仓库内）。
