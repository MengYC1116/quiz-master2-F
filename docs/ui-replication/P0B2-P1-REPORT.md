# P1 报告：删库建库（无迁移）+ 备份版本字段 + §1.2 模型字段

- 日期：2026-11-14
- 方案：`docs/ui-replication/DB-CHANGE-PLAN.md` v2.1（§1.2、§2、§7 P1 行、§8）
- 分支：`ui-replication`（未 commit、未 push）
- 基线：`flutter analyze` 0 问题；全量测试 441 通过 + 0 跳过（含 P0.5 新增 14 项；YOLO 冒烟测试设 `LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux` 后真实跑）
- 结果：**P1 完成**。`flutter analyze` 0 问题；全量测试 **462 通过**（441 基线 + P1 新增 20 + s8b4 新增 1），0 失败；Linux Release 构建成功；Xvfb 真机验证通过（见下）。

## §2 备份版本字段（平铺 + `_meta`，先加后用）

改动（`lib/data/database.dart`、`lib/modules/settings/settings_page.dart`）：

- `backupTables` 由 12 张表增至 **13 张**，加 `question_boxes`；`_meta` 不是表，不在清单里。
- `exportBackupJsonFrom`：顶层仍是表名平铺，额外加 `_meta: {schemaVersion: 2, appVersion: '0.1.0+1'（与 pubspec 一致）, exportedAt}`。新增 `AppDatabase.schemaVersion = 2` / `appVersion` 两个常量（与 sqflite `version` 参数、`PRAGMA user_version` 不是同一口径，注释里写明了）。
- 新增 `validateBackupData`（纯校验，不动库）：① `_meta` 缺失或 `schemaVersion` 非整数 → 拒绝（“这份备份没有版本信息，是旧版（v1）备份，新版不再支持恢复”）；② `schemaVersion > 2` → 拒绝（“这份备份来自更新的版本（v$sv），请先更新应用再恢复”）；③ `< 2` 也拒绝；④ 关键表 `subjects` / `questions` 须为数组；⑤ 每个表的值须为列表、每行须是对象且含主键（各表 `id`，settings 是 `key`）。缺的表键按空表处理（清掉，不报错），与旧语义一致。
- `importBackupJsonInto`：先调 `validateBackupData`，校验不过一律不动原库；校验通过才进事务清表插回。清表/插表只按 `backupTables` 一份清单走（删掉了另一份手写清单；清表顺序为 `question_boxes` 在前 + `backupTables` 倒序，插表顺序为 `backupTables` 正序）。恢复后 `settings.schemaVersion` 写回 `'2'`。
- 新增 `BackupRestoreException`（message 直接展示给用户，须是具体原因）。
- 设置页：导出文件名改为 `quiz-master2-backup.qm2backup`，成功提示改为“备份已保存（此备份仅新版可恢复）”；恢复选择器同时允许 `.json` 与 `.qm2backup`（任务定稿，覆盖方案 §2.3“只含 .qm2backup”的写法——`.json` 选到时按校验拒绝，不静默读坏）；选文件时先调 `validateBackupData` 给即时反馈，确认恢复时数据层再校验一次；`_confirmRestore` 补了 `catch`：`BackupRestoreException` 报具体原因，其他异常报“恢复失败，备份文件可能已损坏，原题库没动”（以前失败是静默的 `finally`）；备份说明文案同步改了一行（“JSON 文件”→“备份文件（.qm2backup）……此备份仅新版可恢复”）。
- 不做：文件级 zip 备份（P3）；导入/检测/切片/修框接线（P2）。

## §2 删老库 + `_onCreate` 建 v2 新库（无迁移、无演示数据）

改动（`lib/data/database.dart`）：

- `OpenDatabaseOptions(version: 2, onCreate: _onCreate)`，无 `onUpgrade`；`onDowngrade` 直接抛错“数据库是新版格式，请用新版打开”，不许静默删库重建。
- 新增 `AppDatabase.openAt(dbPath)`（§8.1 的测试工厂，也是 `_openDb` 的唯一打开入口）：先调 `deleteLegacyDatabaseIfPresent` 再打开。`deleteLegacyDatabaseIfPresent`：文件不存在 → 什么都不做；只读打开读 `user_version`（不触发 `onCreate`/`onUpgrade`）→ `== 2` 不动，`!= 2`（v1 或其他）→ 删除库文件（含 `-wal` / `-shm`）；删除失败或只读打不开 → 抛 `LegacyDatabaseException`，调用方拒绝打开、不建新库、不滑入 fallback 目录（否则新旧库并存）。`_openDb` 里 `LegacyDatabaseException` 直接 rethrow，只有其他打开失败才走原 fallback 目录。
- `_onCreate`：建 v2 全量结构 + 播种；**不再预置演示数据**（§6 第 1 条）：删掉了演示题 9 道、演示解决记录（含“解决中/复查”两条演示状态更新）、演示 `recent_tasks` 一行。保留产品预置项：3 学科、每科 3 个预置文件夹（共 9 个）、预置标签、演示试卷、知识点树；并写 `settings.schemaVersion = '2'`。
- 删掉了 `ensureCollectTasksCreatedAt` 及其在 `_openDb` 里的调用（§2.2 明令删除的回填；新库建表时 `created_at` 列已在）。
- `demo_data.dart` 的 `demoQuestions()` 现无调用方（仅定义保留，未删文件；`demoExams()` / `demoKnowledgePoints()` 仍在 `_seed` 里用）。

## §1.2 模型字段（DDL 为准，不自己发挥）

### （a）`questions` 表：加 7 列（全部可空）

`source_path TEXT`、`source_kind TEXT`、`source_page INTEGER`、`page_image_path TEXT`、`slice_path TEXT`、`slice_width INTEGER`、`slice_height INTEGER`。`slice_kind` / `slice_text` 保留（最小改动，不删列）。`Question` 模型同步加 `sourcePath` / `sourceKind` / `sourcePage` / `pageImagePath` / `slicePath` / `sliceWidth` / `sliceHeight`（全部可空），`copyWith` 照现有 `clearXxx` 模式加了 `clearSourcePath` / `clearPageImagePath` / `clearSlicePath`；`_toRow` / `_fromRow` 照新列读写。

### （b）`collect_tasks` 表：加 2 列 + `page_count` 口径不变

`source_path TEXT NOT NULL DEFAULT ''`（`file_name` 回归只做显示名）、`page_rotations TEXT NOT NULL DEFAULT '{}'`（草稿修框按页旋转 JSON，§1.6.1）；`created_at` 已在建表里（P0 时已有列，本次未动）。`CollectTask` 模型同步加 `sourcePath`（默认 `''`）、`pageRotations`（`Map<int, int>`，默认 `{}`）；`_collectTaskToRow` / `_collectTaskFromRow` 编解码 `page_rotations` JSON（非法值按 `{}` 处理）。`upsertCollectTaskInto` 的 UPDATE-first 逻辑不动，新列随整行写（草稿保存框时旋转一起存，P2 接线时用）。

### （c）新建 `question_boxes` 表（v2 修订版 DDL 原样）

含 `id TEXT PRIMARY KEY`（`box-<taskId>-p<page>-<uuid8>`，调用方生成）、`collect_task_id TEXT`（可空）、`question_id TEXT`、`parent_box_id TEXT`、`page INTEGER NOT NULL DEFAULT 1 CHECK (page >= 1)`、`layer INTEGER NOT NULL CHECK (layer IN (1, 2))`、`type TEXT NOT NULL CHECK (type IN ('question', 'stem', 'option', 'figure'))`、`x/y/w/h REAL NOT NULL CHECK (0..1)`、`confidence REAL CHECK (NULL 或 0..1)`、`origin TEXT NOT NULL DEFAULT 'manual' CHECK (origin IN ('yolo', 'manual'))`、`updated_at INTEGER NOT NULL`；4 个索引：`idx_boxes_task_page`、`idx_boxes_question`、`idx_boxes_parent`、partial unique `idx_boxes_one_layer1_per_question … WHERE layer = 1 AND question_id IS NOT NULL`。

`QuestionBox` 模型同步扩展（不另建 `StoredQuestionBox`）：`confidence` / `origin`（默认 `'manual'`）/ `parentBoxId` / `page`（默认 1）/ `collectTaskId` / `questionId` / `updatedAt`，另加 `copyWith`（含 clear 标志）。`database.dart` 加 `_questionBoxToRow` / `_questionBoxFromRow` 及可单测静态入口 `insertQuestionBoxInto` / `boxesForQuestionFrom`（P2 接线时用；P1 不做框的业务读写）。

删除规则（写进代码，不只写文档，§1.2(c)）：删题时同事务删该题的框（含 `parent_box_id` 指向该题整题框的子框，`_deleteQuestionTxn`）；删任务时同事务只删未确认的草稿框（`collect_task_id = ? AND question_id IS NULL`，`deleteCollectTaskFrom`，已确认的框随题保留）；`deleteCollectTask` / `upsertQuestion` 另拆出可单测静态版（`deleteCollectTaskFrom` / `upsertQuestionInto` / `allQuestionsFrom`，与既有 `*From` 模式一致）。

不做：`question_slices` 表、`source_files` 表（§1.2(d)）；`QuestionBox.rotation`（单框旋转已禁用，§6 第 10 条）。

### 未动的 P0.5 共享 helper

`lib/services/page_image_pipeline.dart` 未动。

## §8 测试（随 P1 做）

新增 `test/p1_schema_backup_test.dart`（20 项），全部用内存库/临时目录，不碰真实库：

- schema 结构（5 项）：`questions` 7 列类型+可空、`slice_kind`/`slice_text` 保留；`collect_tasks` 三列类型/非空/默认值；`question_boxes` 14 列 + 全部 CHECK 文本 + 4 个索引 + partial unique 的 `WHERE` 子句；CHECK 生效（越界坐标/layer 3/置信度 2/非法 origin/page 0 各拒绝写入）；partial unique（一题两个 layer=1 框拒绝；`question_id` 为 NULL 的草稿框与 layer=2 框不受限）。
- 删老库建新库（3 项）：造 v1 库（version 1 + 旧表旧行 + 假 `-wal`/`-shm`）→ 删老库返回 true、文件与 `-wal`/`-shm` 全删 → `openAt` 建出 v2（`user_version` 2、旧表消失、0 题、演示题 0、3 学科、9 文件夹、`settings.schemaVersion='2'`）；已是 v2 的库不删、重开数据还在；不存在的库直接建 v2。
- 模型字段往返（5 项）：Question 7 列、`QuestionBox` 行转换（confidence/origin/parent/page/归属）、CollectTask `source_path`/`page_rotations`（`{1: 90, 2: 0}`）、删题级联删框（含子框）、删任务只删草稿框。
- v2 备份恢复（7 项）：导出平铺 + `_meta`（schemaVersion 2、appVersion、exportedAt）+ 13 张表；备份→清空→恢复一轮（题/框/任务回来，`schemaVersion` 写回 2）；`schemaVersion > 2` 拒绝且原库不动；`_meta` 缺失（v1）拒绝且原库不动；`schemaVersion` =1 / 非整数拒绝；关键表不全/行缺主键/表不是列表拒绝且原库不动；缺表键恢复不崩（缺的表清空，其余恢复）。

更新 `test/s8b4_backup_migration_test.dart`（备份组改用 `createTables` 合成库，**不再读真实用户库**——§8.1 禁止新测试依赖真实库，且 P1 删老库后真实库从空开始，旧写法“断言演示库 9 道题”必挂；B4.3 迁移复制组未动）：表数断言 12→13、导出断言加 `_meta` 与 `question_boxes`、题数断言 9→2（合成库 2 道题）、新增“没有 `_meta` 的 v1 备份拒绝恢复、原库不动”1 项。

## 验证结果

- `flutter analyze`：**0 问题**（改动前后各一次，最终构建前一次）。
- 全量 `flutter test`（`LD_LIBRARY_PATH=…/onnxruntime-1.4.1/linux`，YOLO 冒烟真实跑）：**462 通过，0 失败**（基线 441 + P1 新增 20 + s8b4 新增 1；文案改动后重建又复跑一次，仍是 462 通过）。
- Linux Release 构建：成功（`build/linux/x64/release/bundle/quiz_master2`）。
- Xvfb 真机实测（Release 包，`xvfb-run -a`，1280×800）：
  - 先把 `/tmp/qm2-v1-demo-backup/quiz-master2.db`（v1，9 道题）恢复到真实位置，再启动应用：应用存活，库被删掉重建为 **v2、0 道题、3 学科、9 文件夹、`settings.schemaVersion='2'`**；首页显示“今天没有要复习的，明天再来吧”、各科 0 道（截图见 `/tmp/qm2-shot1.png`，截图免交、仅本地留存）。
  - 备份导出/恢复：对应用真实建出的 v2 库文件副本做导出→写 `.qm2backup`→恢复→篡改 `schemaVersion=3` 拒绝，全流程通过（临时测试 `test/zz_p1_realfile_verify_test.dart`，跑完已删，不进仓库）。GUI 点按验证未完成：设置页→数据→“备份题库”点了两次都只弹“备份没存上”——原因是本机无 `zenity` / `kdialog` / `qarma` / `xdg-desktop-portal`，`file_picker` 8.3.7 在 Linux 下靠这些外部程序弹原生文件对话框，打不开就抛错（`_backup` 的 catch 接住后弹提示并记 `backupFailed` 标志）。这是**环境缺件、与 P1 无关**（旧版同一位置同样打不开）；`apt-get update` 尝试装 zenity 超时过久已放弃。导出文件名、内容与恢复校验由上面单测+真实文件测试覆盖。
  - 另：`settings.schemaVersion` 读回为 `2`；两次失败备份后 `backupFailed` 标志为 `1`（符合既有“备份失败首页横幅”逻辑，下次备份成功即清）。
- 演示库恢复：验证结束后已把 `/tmp/qm2-v1-demo-backup/quiz-master2.db` 恢复回真实位置，经 `sqlite3` 核对 **user_version=1、9 道题、3 学科**，与 P1 前原状一致，未留空库。（注意：按 §6 第 1 条，下次启动应用仍会删掉它重建为空库——这是 Meng 已定的行为。）

## 遗留与注意

1. 全量测试期间，既有的 `p0_hardening_test.dart`“并发 await db”单测会打开**真实库单例**（`AppDatabase.instance.db`，P0 时即如此）。P1 代码落地后它第一次跑就触发了删老库（v1 被删、重建 v2 空库）。当时 `/tmp` 备份已在手，未丢数据；之后为做 Xvfb 验证又恢复过一次 v1，验证完再次恢复原状。后续跑全量测试前若在意真实库被删，须先备份——或将来把该单测改成不碰真实单例（不在 P1 范围，未改）。
2. `demoQuestions()` 现无调用方，仅定义保留在 `lib/data/demo_data.dart`，analyzer 不报错；是否删除由后续清理定。
3. 本次未改产品 UI 流程（除备份文件名/提示/说明文案一行）；未碰 `page_image_pipeline.dart`；未写任何老数据迁移代码；未 commit、未 push。
