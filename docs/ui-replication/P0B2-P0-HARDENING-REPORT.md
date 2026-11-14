# P0 数据层加固报告（DB-CHANGE-PLAN.md §4.1–§4.5）

- 日期：2026-11-14
- 分支：`ui-replication`（未提交、未推送，按任务要求）
- 结论：§4.1–§4.5 全部完成并通过验证。`flutter analyze` 0 问题；全量测试 **426 通过 + 1 跳过 = 427 项**（基线 415 项 + 新增 12 项）；Linux Release 构建成功；Xvfb 真机（演示库）备份恢复一轮通过，笔记含 Tab/CR 往返一致；演示库已恢复原状。
- 范围：只动数据层与备份相关代码（`lib/data/database.dart`、`lib/data/repository.dart`、`lib/models/models.dart`）+ 新增回归测试 `test/p0_hardening_test.dart`。**没动**：迁移/删库逻辑、版本号（仍为 version 1，无 `onUpgrade`）、UI、依赖、P2 的 4 个实施注意（旋转后恢复自动框坐标变换、EXIF 检测实现、uuid8 生成、`detectPage` 传页图路径——已另行记录，P2 时再带）。

## 基线（改前核对）

- `flutter analyze`：0 问题。
- 全量 `flutter test`：414 通过 + 1 跳过 = 415 项（含三处小修新增的 7 项），与任务给出的基线一致。

## §4.1 `AppDatabase.db` 缓存 `Future<Database>`，消并发竞争

### 做了什么

- `lib/data/database.dart`：新增 `_dbFuture` 字段；`db` getter 改为缓存 Future 本身（`_dbFuture ??= _openDb().then(...)`），启动时多处同时 `await db` 只打开一次连接。原先 `if (_db != null)` 的写法并发调用会各自 `openDatabase`，旧连接泄漏、多连接同时写同一文件。
- 打开逻辑抽成 `_openDb()`（建目录 / 打开 / 数据目录不可写时回退到可执行文件同级 `data/`，与原来一致）；打开失败时把 `_dbFuture` 置空（失败的 Future 不被永久缓存，下次重试重新打开）。
- `migrateToDirectory` 关库时同时清 `_db` 与 `_dbFuture`（原来只清 `_db`，已缓存的 Future 会继续返回已关闭的库）。

## §4.2 `recordSelfCheck`、`deleteSubject` / `deleteFolder` 加事务

### 做了什么

- 新增 `AppDatabase.recordSelfCheckTxn` / 可单测版 `recordSelfCheckInto(db, ...)`：改错因记录 → 记自查历史 → 题目自查次数 +1 三步同事务；失败整体回滚。`repository.recordSelfCheck` 改调它（原来三次独立写）。角标 `bumpBadgeVersion()` 移到提交成功后调一次，事务内不调 UI 通知。题目次数改用 `UPDATE ... SET review_count = review_count + 1`（与原来读出来 +1 再写回等效，且无竞态）。
- `deleteSubject`：整科一次 `db.transaction`（可单测版 `deleteSubjectFrom`）；中途失败整体回滚。
- `deleteFolder`：递归改传 `Transaction` 进去（`_deleteFolderTxn`），顶层一次事务包住整棵子树，不开嵌套事务（sqflite 不支持嵌套事务）；可单测版 `deleteFolderFrom`。原来每题调一次 `deleteQuestion`（各开各的事务），中途失败会留半截。
- 同批事务化：`deleteQuestion`（`deleteQuestionFrom`）、`clearDemoData`（`clearDemoDataFrom`，见 §4.5）。
- 共用抽取：`_causeRecordToRow`（`upsertCauseRecord` 与事务入口共用同一份行映射）。

### 没做的（§4.2 附带，任务未列）

- `deleteChapter` / `deleteKnowledgePoint` / `renameTag` / `deleteTag` 仍是多步写、无事务，留待后续批次；`importBackupJsonInto` 本来已有事务，不动。

## §4.3 `upsertCollectTask` 改 UPDATE-first + `created_at` 稳定排序

### 做了什么

- `upsertCollectTask` 改 UPDATE-first（照 `upsertSubject` 的正面先例）：已存在的行只 `UPDATE`，不碰 `created_at`，`rowid` 不变、顺序不动；不存在时才 `INSERT`。可单测版 `upsertCollectTaskInto(db, t)`。
- `collect_tasks` 加 `created_at INTEGER NOT NULL DEFAULT 0` 列（`createTables` 建表语句里，`_onCreate` 共用）；`allCollectTasks` 改 `ORDER BY created_at DESC, rowid DESC`（同毫秒建的批量任务用 `rowid` 兜底）。
- `CollectTask` 模型加可空 `createdAt` 字段；新建任务调用方没给时写当前时间；`UPDATE` 永不改 `created_at`。
- **已存在旧库的衔接**：`_openDb()` 打开成功后调 `ensureCollectTasksCreatedAt(db)`——`PRAGMA table_info` 检查缺列时才 `ALTER TABLE ... ADD COLUMN created_at INTEGER NOT NULL DEFAULT 0`。只做加列，**不改版本号、不加 `onUpgrade`、不迁移数据、不删库**；加列失败（如只读库）不阻塞启动、忽略。新建库建表时已有该列，检查是空操作。本机真实演示库已在验证中补上该列（见“验证”）。

### 没做的

- §4.3 的角标刷新节流（只在状态变化时 bump / debounce）任务未列，未做；`upsertQuestion` / `upsertCauseRecord` 的 REPLACE 仍按方案 §4.3 定稿保留（不影响可见顺序）。

## §4.4 备份手写 `_jsonValue` 改 `dart:convert` 的 `jsonEncode`

### 做了什么

- `exportBackupJsonFrom` 改为 `jsonEncode(out)`（`dart:convert`，Flutter 自带，无新依赖）；删掉手写 `_jsonEncode` / `_jsonValue`（只转义 `\`、`"`、`\n`，漏 `\r`、`\t`、`\b`、`\f` 与其它控制字符，含制表符或回车的笔记会导出非法 JSON、恢复不了）。
- 旧备份文件若本身已含未转义的控制字符，新版 `jsonDecode` 恢复时会失败——按方案 §2.4 的口径，校验不过就不动原库并提示备份文件已损坏；不写容错解析器。

## §4.5 删除 / 清空补级联清理（孤儿行）

### 做了什么

| 删除动作 | 补的级联（同事务） |
|---|---|
| `deleteQuestion(id)` | `review_history`（该题自查历史）；`collect_tasks.question_id` 置 `NULL`（任务本身保留）；`review_state.queue` 里该题的 `"qid\|cause"` 项去掉；`cause_records`（原有）+ 题目行 |
| `deleteSubject(id)` | 经 `_deleteQuestionTxn` 逐题清上面各项；再删该科 `collect_tasks` 行、`recent_tasks` 里该科行；文件夹 / 知识点 / 学科行（原有） |
| `deleteFolder(f)` | 随 `_deleteQuestionTxn` 的修复自动补齐；递归本身见 §4.2 的事务化 |
| `clearDemoData()` | 演示题的 `review_history`；`recent_tasks`（整表，演示的最近任务行）；`review_state` 断点（原有 `clearReviewState` 的口径，改为事务内删）；非演示数据不动 |

- 文件级联未做：§1 的落盘还没落地（没有 `imports/` / `slices/` 文件、`question_boxes` 表也不存在），按方案 §4.5 定稿“文件级联随 §1 的落盘一起上”；孤儿文件清理入口同样随 §1 之后上。规则仍是“宁留孤儿，不误删”。

## 验证

### 静态与单测

- `flutter analyze`：0 问题。
- 全量 `flutter test`：**426 通过 + 1 跳过 = 427 项**（基线 415 + 新增 12）。
- 新增 `test/p0_hardening_test.dart`（12 项，内存库 + `AppDatabase.createTables` 建表，不碰真实库；只有 §4.1 一项走单例 `db`）：

| # | 覆盖 | 结果 |
|---|---|---|
| 1 | §4.1 并发 `await db` 三次是同一 `Database` 对象（只 open 一次），串行再取仍是同一连接 | 通过 |
| 2 | §4.4 笔记含 Tab/CR/控制字符（`\x01`、`\x08`、`\x0c`、反斜杠、引号、换行）：导出是合法 JSON，恢复后内容一致 | 通过 |
| 3 | §4.2 `recordSelfCheckInto` 成功：三步都写（`solved_count` 1、`review_history` 1 行、`review_count` +1） | 通过 |
| 4 | §4.2 `recordSelfCheckInto` 中途失败（触发器让写 `review_history` 必失败）：三步整体回滚 | 通过 |
| 5 | §4.2 `deleteSubjectFrom` 中途失败（触发器让删题必失败）：整科整体回滚 | 通过 |
| 6 | §4.2 `deleteFolderFrom` 中途失败：文件夹与题整体回滚 | 通过 |
| 7 | §4.2 `deleteFolderFrom` 成功：子文件夹递归、多文件夹的题只移走关联 | 通过 |
| 8 | §4.3 多次进度更新不改变任务顺序、`rowid` 不变 | 通过 |
| 9 | §4.3 新建写 `created_at`、更新不改 `created_at`、同毫秒用 `rowid` 兜底 | 通过（初版期望写错：新建任务的 `created_at` 是真实当前时间，比测试用的 5000ms 大、排第一是正确的；已修正期望，产品代码未动） |
| 10 | §4.5 `deleteQuestionFrom`：无孤儿行（`review_history` 清、任务指向置空且任务保留、队列去项） | 通过 |
| 11 | §4.5 `deleteSubjectFrom`：清该科 `collect_tasks` / `review_history` / `recent_tasks`，他科数据不动 | 通过 |
| 12 | §4.5 `clearDemoDataFrom`：清演示复习历史与 `recent_tasks`，非演示不动 | 通过 |

- 另：`AppDatabase.createTables(db)` 是新增的测试用建表入口（与 `_onCreate` 共用同一份建表语句、不播种演示数据），供内存库测试与将来其它数据层测试复用。

### Linux Release 构建

- `flutter build linux --release` 成功：`build/linux/x64/release/bundle/quiz_master2`（Flutter 3.47.9；工具链无缺失，未跑 `restore-linux-toolchain.sh`）。

### 真机实测（Xvfb 1280×720，演示库）

备份恢复一轮，全程走真实应用（Release 构建）：

1. 错题本 → 数学 → 全部题目 → 第一道题（`q-math-3`，定积分阴影面积）→ 编辑 → 备注字段粘贴笔记 `P0验证<Tab>制表符<CR>回车符`（剪贴板粘贴，`xdotool key Tab` 在输入框里是切焦点、打不出制表符）→ 保存。查库：`q-math-3` 的 `notes` 为 `'P0验证\t制表符\r回车符'`，Tab 与 CR 都在。
2. 设置 → 数据组 → 备份题库（本机无 zenity，用垫片 `/tmp/qm2-bin/zenity` 按 S8B4 的做法返回固定路径，只在本次验证的 PATH 里生效）。应用写出 `/tmp/qm2-p0hardening-backup.json`（10,542 字节）：12 张表、9 道题，笔记在 JSON 里完好（`\t`、`\r` 均正确转义，`json.load` 通过）。
3. 库里把笔记改成 `已改掉` 模拟丢失 → 设置 → 选择备份文件… → 内联确认“将用备份文件 `qm2-p0hardening-backup.json`（9 道题）覆盖现在的题库（当前 9 道题）”→ 确认恢复。查库：`q-math-3` 的 `notes` 回到 `'P0验证\t制表符\r回车符'`，9 道题、3 学科。
4. 演示库已恢复原状：从验证前备份的 `/tmp/qm2-p0hardening-orig.db` 恢复，核对 9 道题、3 学科、深色（`themeMode=dark`）、`pageSize=10`、`startupPage=home`、无笔记行、无 `db_location.txt` 标记文件。恢复的库含 `collect_tasks.created_at` 列（验证前备份时已有——§4.1 测试触发的 `ensureCollectTasksCreatedAt` 补的列；下次启动应用也会自动补）。

## 备注

- `addCauseCheckHistory` 在 `repository.recordSelfCheck` 改走事务后不再被库内调用，保留为公开方法（未删，保持最小改动）。
- 本次验证中途 `MEMORY.md` 被外部改动（与本任务无关，未受影响）。
- 探针截图只存在 `/tmp/qm2-probe-*.png`，未进仓库（按 2026-11-14 新口径，真机验证不留截图）。
