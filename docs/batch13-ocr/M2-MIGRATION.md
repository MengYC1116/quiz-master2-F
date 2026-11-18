# M2 报告：数据库 v3→v4 迁移 + ocr_jobs 表 + 备份互通

- 批次：十三批，模块 M2
- 时间：2026-11-18
- 范围：只做表结构、迁移、备份互通。未碰 OCR 客户端、队列 worker、切分、UI（M3/M4/M5 的事）；未给 Meng 发邮件/消息；未推送代码；未做任何 git 操作（本地 HEAD bca8586 是 stale 的，工作区此前已有其他模块的未提交改动）。
- 演示库：跑测试前已备份到 `~/workspace/demo-db-backup/quiz-master2.db.b13-m2-start`；跑后 `quiz-master2.db` md5 仍为 `8f7f9c64405dc6e484ac2bf8e5e1a807`，不变。

## 1. 改动文件清单

### 生产代码（9 个文件 + 1 个生成文件）

| 文件 | 改动 |
|---|---|
| `lib/data/database.dart` | `schemaVersion` 3→4；`backupTables` 加 `ocr_jobs`（15 张）；新增 `backupTablesV3`（v3 的 14 张，供 sv3 备份校验用） |
| `lib/data/db_schema.dart` | `createTablesImpl`：questions 加 5 个 OCR 列；新建 `ocr_jobs` 表 + 2 个索引；`_seed` 写 `schemaVersion='4'`；打开入口注释 v3→v4 |
| `lib/data/drift/tables/questions.dart` | Questions 表加 5 列（与 DDL 逐字对应） |
| `lib/data/drift/tables/ocr_jobs.dart` | **新建**：OcrJobs 表定义 |
| `lib/data/drift/quiz_database.dart` | 注册 `OcrJobs`；`schemaVersion` 3→4；`onUpgrade` 改为 3→4 单步 + 2→4 两步链式（2→3 步抽成 `_upgrade2To3`，3→4 步为 `_upgrade3To4`） |
| `lib/data/drift/quiz_database.g.dart` | build_runner 重新生成（含 `OcrJobs` 与 questions 新列；另有 1 条 `tags.dart` 的既有 drift_dev 提示，非本次引入） |
| `lib/models/models.dart` | `Question` 加 5 个 OCR 字段 + copyWith（含 `clearOcrRaw`/`clearOcrStem`）；新增 `OcrSplitStatus` 常量、`OcrJobStatus` 枚举 + 中文 label、`OcrJob` 模型类 |
| `lib/data/db_questions.dart` | `_questionFromDb` / `_questionCompanion` 加 5 个 OCR 列全列往返（缺了这段，整行写回会把库里的 OCR 值抹回默认值） |
| `lib/data/db_backup.dart` | 校验接受 sv 2/3/4（按版本取表清单）；`ocr_jobs` 必填列/值域/路径校验；questions 新列值域校验；插库分流 + 清表加 `ocr_jobs`；`_missingReferencedFiles` 加 `crop_path` |
| `lib/data/db_orphans.dart` | `_referencedRelativePaths` 加 `ocr_jobs.crop_path`（进 zip 备份、不被当孤儿删） |

### 测试（1 新 + 5 改）

| 文件 | 改动 |
|---|---|
| `test/b13_migration_test.dart` | **新建**，17 项（见 §4） |
| `test/b1_stage1_schema_test.dart` | v4 基线：21 条 DDL（15 表 + 6 索引），user_version=4 |
| `test/b12_schema_v3_migration_test.dart` | v2→v3 改为 v2→v4 链式（断言 3→4；单步 v3→v4 见新 b13 文件） |
| `test/p1_schema_backup_test.dart` | 导出 15 张表、schemaVersion 写回 4、>4 拒绝、v2 备份恢复进 v4 |
| `test/s8b4_backup_migration_test.dart` | backupTables 14→15 张，含 `ocr_jobs` |
| `test/b3_backup_interop_test.dart` | 黄金夹具重导出差异 8→17 处（settings `2 → 4` + 3 道题 × 3 个新列默认值） |

未改 `docs/decision-log.md`：工作区里它已有其他模块的未提交改动，为避免冲突，D-107 条目请统筹在合批时补记（内容见本报告 §5）。

## 2. Schema v4 内容

### questions 新增 5 列（DDL 位置：`slice_height` 之后）

```sql
ocr_raw TEXT,                                   -- 原始 OCR 结果（内部存，TEXT，可空）
ocr_stem TEXT,                                  -- 切分后题干（TEXT，可空）
ocr_split_status TEXT NOT NULL DEFAULT '未切分', -- 切分状态
ocr_manual_edited INTEGER NOT NULL DEFAULT 0,   -- 人工编辑标记（0/1）
content_version INTEGER NOT NULL DEFAULT 0      -- 内容版本
```

- `ocr_split_status` 取值（中文原文，见 `OcrSplitStatus`）：`未切分` / `自动切分` / `存在歧义` / `人工调整`；默认 `未切分`。
- `content_version` 默认 0；递增规则由 M3 定（建议：每次 OCR 自动应用或人工编辑保存时 +1，供 worker 校验“任务开始后内容是否变过”）。
- 模型层：`Question.ocrRaw / ocrStem / ocrSplitStatus / ocrManualEdited / contentVersion`（`lib/models/models.dart`，类型定义只在一处）。

### ocr_jobs 表（新建，GPT 评审 §2.2 字段表）

```sql
CREATE TABLE ocr_jobs(
  id TEXT PRIMARY KEY, question_id TEXT NOT NULL,
  crop_path TEXT, input_hash TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  attempt_count INTEGER NOT NULL DEFAULT 0,
  available_at INTEGER, started_at INTEGER, lease_until INTEGER,
  last_error_code TEXT, last_error_message TEXT,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
  completed_at INTEGER);
CREATE INDEX idx_ocr_jobs_question ON ocr_jobs(question_id);
CREATE INDEX idx_ocr_jobs_pending ON ocr_jobs(status, available_at);
```

时间统一 INTEGER 毫秒时间戳（项目既有约定）。索引说明：`idx_ocr_jobs_question` 供按题查任务；`idx_ocr_jobs_pending` 供 worker 领任务（`status='pending' AND available_at<=now`）。

## 3. M3 接口契约（ocr_jobs 字段定义，M3 按此接）

| 列 | 类型 | 可空 | 含义 / 约定 |
|---|---|---|---|
| `id` | TEXT PK | 否 | OCR 任务唯一 ID（应用生成，如 `ocr-<uuid>`，与 collect_tasks 的 id 口径一致，不用自增） |
| `question_id` | TEXT | 否 | 对应题目 ID |
| `crop_path` | TEXT | 是 | 本次识别使用的切片路径，相对数据目录，`imports/` 或 `slices/` 下（与 `questions.slice_path` 同口径；备份校验按该口径拦非法路径；zip 备份会打包它） |
| `input_hash` | TEXT | 是 | 切片内容的 SHA-256。任务完成时须重算切片哈希比对，不一致不自动应用结果（旧切片结果不得写入新切片对应的题）；NULL 表示无基线（v3 迁移/旧备份无此概念，不适用） |
| `status` | TEXT | 否 | `pending` 待处理 / `running` 进行中 / `completed` 已完成 / `failed` 失败；默认 `pending`。模型层枚举 `OcrJobStatus`（`lib/models/models.dart`，含中文 label） |
| `attempt_count` | INTEGER | 否 | 实际发起请求的次数，首次请求算 1；“重试 3 次”= 最多 4 次请求；默认 0 |
| `available_at` | INTEGER | 是 | 下次允许重试的时间（退避到期点毫秒戳）；NULL = 立即可跑 |
| `started_at` | INTEGER | 是 | 本次开始处理时间 |
| `lease_until` | INTEGER | 是 | worker 处理租约到期时间；启动时只回收租约已过期的 `running` 任务 |
| `last_error_code` | TEXT | 是 | 最近一次错误类型，如 `api_key_missing` / `timeout` / `http_429`（具体码表由 M3 定） |
| `last_error_message` | TEXT | 是 | 最近一次错误信息 |
| `created_at` | INTEGER | 否 | 创建时间 |
| `updated_at` | INTEGER | 否 | 更新时间 |
| `completed_at` | INTEGER | 是 | 完成时间；成功或失败终态都填，`pending`/`running` 为 NULL |

补充约定（M3 注意）：

1. **不要给 ocr_jobs 加唯一约束**：同一题可有多条任务（重识别、改框后新任务）；去重/幂等由 worker 层做（按 `question_id + input_hash` 查未完成任务），不在表上锁死。
2. **应用 OCR 结果前必查三项**（GPT §2.7）：切片 hash 与 `input_hash` 一致、题目仍存在、`content_version` 与任务领取时一致；任一不符不自动覆盖。用户已人工编辑（`ocr_manual_edited=1`）的结果，OCR 新结果只作候选，不自动覆盖。
3. **`Question` 模型已带 OCR 字段**，`upsertQuestionInto` 全列写回；M3 写 OCR 结果时走 `Question.copyWith(ocrRaw/ocrStem/ocrSplitStatus/contentVersion: +1)` 再 upsert，不要手写 SQL。
4. **`crop_path` 必须是 `imports/`/`slices/` 下的相对路径**，否则备份恢复会拒绝整个备份（与 questions 的路径口径一致）。
5. **无 API Key 时只排队不发请求**：任务保持 `pending`，`available_at` 可置空或置一个远期值由 M3 定，不要写成 `failed`（`failed` 只用于终态失败）。

## 4. 迁移与备份互通口径

- **迁移**：`onUpgrade` 走 `customStatement` 手写字面量（十二批 D-91 的教训，不用 `m.createTable`/`m.addColumn`）。`3→4`：questions 加 5 列 + 建 `ocr_jobs` + 2 索引 + settings 写回 `'4'`；`2→4`：先跑 2→3 步再跑 3→4 步；`from > to` 抛“请用新版打开”；v1（<2）仍由打开前预检删除。全新安装直接建 v4。
- **DDL 一致性**：迁移后库与全新 v4 库 `sqlite_master` 逐字一致（空白折叠后比对，测试锁定）。
- **备份互通**：导出/校验/导入同时接受 schemaVersion 2、3、4；>4 与 <2 拒绝。
  - sv2 备份：按 13 张表校验；`recently_viewed_questions`、`ocr_jobs` 缺键视为 empty；`collect_tasks` 行缺 `source_hash` 为 NULL；questions 行缺 OCR 列走 DDL 默认值。
  - sv3 备份：按 14 张表校验；`ocr_jobs` 缺键视为 empty；questions 行缺 OCR 列走 DDL 默认值。
  - sv4 备份：按 15 张表校验，全量往返。
  - 恢复后 settings.schemaVersion 一律写回当前版本 `'4'`。
- **主键校验（D-101 教训）**：按每张表的真实主键列校验——`recently_viewed_questions`→`question_id`、`settings`→`key`、`ocr_jobs`→`id`、其余→`id`；整数主键表（cause_records/review_history/review_state/recent_tasks）沿用原有口径。
- **值域校验新增**：`questions.ocr_split_status` ∈ {未切分, 自动切分, 存在歧义, 人工调整}；`questions.ocr_manual_edited` ∈ {0, 1}；`ocr_jobs.status` ∈ {pending, running, completed, failed}。键缺失放行（走 DDL 默认值），键在但值非法拒绝整个恢复。
- **路径校验新增**：`ocr_jobs.crop_path` 与 questions/collect_tasks 同口径（只允许 `imports/`/`slices/` 下相对路径）。
- **zip 备份**：`ocr_jobs.crop_path` 引用的文件进包（与 `questions.slice_path` 去重后同一条时只进一次）；恢复后文件与任务行一起回来。只被 `crop_path` 引用的文件不算孤儿（孤儿扫描已覆盖）。

## 5. 测试结果

测试环境：`TMPDIR=$HOME/workspace/flutter-test-tmp`，`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`，`flutter test --concurrency=1`。`flutter analyze`（15 个改动文件）：**No issues found**。

| 文件 | 通过 |
|---|---|
| `test/b13_migration_test.dart`（新，17 项） | 17/17 |
| `test/b1_stage1_schema_test.dart` | 1/1 |
| `test/b12_schema_v3_migration_test.dart` | 4/4 |
| `test/b12fix_d101_backup_pk_test.dart` | 5/5 |
| `test/p1_schema_backup_test.dart` | 见下 |
| `test/s8b4_backup_migration_test.dart` | 见下 |
| `test/b3_backup_interop_test.dart` | 见下 |
| 第一批合计（b13+b1+b12+d101） | **27/27** |
| 第二批合计（p1+s8b4+b3） | **46/46** |
| 邻近备份链路保险（b5_p2_data、p3、fr07、b2_restore_flow、b2_restore_journal） | **148/148** |
| **本模块共计** | **221/221，全过** |

新 b13 文件 17 项覆盖：v3→v4 迁移数据完整 + 新列默认值；迁移后 DDL 与全新 v4 库逐字一致；全新 v4 库含 ocr_jobs 两索引；Question OCR 字段模型往返（含 copyWith 改版不抹 OCR 值、clearOcrRaw 清空）；sv4 往返（OCR 字段 + 2 个 ocr_jobs 行全对）；sv3 备份恢复（ocr_jobs 缺键 empty、OCR 列默认值、历史正常回来）；sv2 备份恢复；sv5/sv1 拒绝且原库不动；含 4 条浏览历史的备份往返成功（D-101 回归：不再报“缺少主键 id”）；ocr_jobs 行缺 id / 缺 question_id / status 非法 / crop_path 非法（绝对路径与 `..` 穿越）拒绝；questions ocr_split_status 非法 / ocr_manual_edited=2 拒绝；zip 往返（crop 文件进包、恢复后文件与任务行都回来）；只被 crop_path 引用的文件不是孤儿。

已知非问题：跑 b12fix 文件时有一条 Drift “一个测试里开了两个内存库”的 debug 警告，与 D-101 记录的既有模式相同，非本次引入。

## 6. 遗留与建议（给统筹）

1. **decision-log D-107 待补记**（本报告 §2–§4 即条目内容）：v3→v4 迁移做法、ocr_jobs 字段表、备份互通口径（sv2/3/4）、D-101 口径沿用。未直接写 `docs/decision-log.md` 是因为工作区里它已有其他模块的未提交改动。
2. **全量测试是 M7 的事**：本模块只跑了上述 12 个文件 221 项；`Question` 加字段理论上只影响有默认值的可选构造参数，但全量仍需 M7 复核。
3. **M3 接手点**：`OcrJob` 模型 + `OcrJobs` Drift 表已就位；worker 的领任务/写结果方法建议新开 `lib/data/db_ocr_jobs.dart` part 文件（仿 `db_recently_viewed.dart` 的单表 part 模式），不要塞进 `db_backup.dart` 或 `db_questions.dart`。
