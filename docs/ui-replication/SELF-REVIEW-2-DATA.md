# 第二次自审 · 数据层报告（SELF-REVIEW-2-DATA）

- 日期：2026-11-15
- 范围：`lib/data/` 全部（`database.dart`、`db_paths.dart`、`db_schema.dart`、`db_storage.dart`、`db_codec.dart`、`db_questions.dart`、`db_catalog.dart`、`db_collect.dart`、`db_orphans.dart`、`db_settings.dart`、`db_backup.dart`）、`lib/models/models.dart`、`lib/data/repository.dart`、`lib/data/demo_data.dart`；为核实调用关系另读了 `lib/services/import_service.dart`、`lib/services/zip_archive.dart`、`lib/modules/collect/collect_page.dart`（`_confirmSplit` / `enqueue` 调用点 / 草稿保存）、`lib/modules/collect/box_editor.dart`（归一化与 `_currentDraft`）、`lib/modules/detail/question_detail_page.dart`（重框段）、`lib/modules/report/report_page.dart`（Top5 与分布）、`lib/modules/home/home_page.dart`（焦点卡）、`lib/modules/wrongbook/wrongbook_page.dart`（封面计数入口）。
- 分支：`ui-replication`；工作树 `~/workspace/quiz-master2-UI`，Batch 1～5 改动全部未提交。
- 方式：逐文件通读 + 对照 `SELF-REVIEW-DATA.md` 证据逐条核对 + 针对性单测验证 + 临时探针测试（5 个，跑完已删除，不留痕）。
- 结论：**新问题 9 个：P1 3 个，P2 6 个**。另有测试质量缺口 8 处（见“新增测试质量”一节，其中 SR-P2-6 零覆盖且 B5 报告称“已测”与事实不符）。`reviewCount` 遗留已核实（见专节）。

## 验证结果汇总

- 目标测试复跑（`--concurrency=1`，`LD_LIBRARY_PATH` 含 onnxruntime-1.4.1）：`b5_p2_data_test.dart` + `b5_p0_1_orphan_test.dart` + `b5_p1_3_delete_exam_test.dart` + `b5_p1_1_subject_counts_test.dart` = **46/46 通过**；`import_service_p1_fixes_test.dart` + `b5_p1_256_test.dart` + `p1_schema_backup_test.dart` + `s8b4_backup_migration_test.dart` = **45/45 通过**；`flutter analyze lib/data lib/models` = **No issues found**。
- 临时探针 `test/sr2_data_probe_test.dart`（5 个，全部按“修好应通过”写）：**5 个全失败，即 5 个问题全部复现**（P-A、P-B、P-C、P-D、P-E），探针文件已删除。
- 演示库：跑前备份到 `~/workspace/demo-db-backup/quiz-master2.db.sr2-data-before`，跑完 md5 仍为 `8f7f9c64405dc6e484ac2bf8e5e1a807`（v1、9 题）。
- 环境插曲：复核中途 VM 重启，`clang`/`ninja` 丢失（`/tmp/clang-shim` 同失），`flutter test` 一度报 `Building native assets failed`；`docs/ui-replication/restore-linux-toolchain.sh` 原样跑两次均在拉取 Packages.gz 索引时 `IncompleteRead` 中断，改用 curl 断点续传先取 4 份索引、再跑同款解包逻辑恢复（clang 18.1.3、ninja 1.12.1、GTK 3.24.41），之后测试全部跑通。另：重启前的一次后台测试运行（`proc_a97d2904b571`）无确认结果、日志为空，已按未知结果处理并重跑，结论以重跑为准。

---

## P1

### SR2-DATA-1 — SR-P1-4 未修完：图片分支尾部 `upsertCollectTask` 仍在 try 之外，写库失败逃出 `enqueue`
- 位置：`lib/services/import_service.dart:359`（图片分支尾部）；调用点 `lib/modules/collect/collect_page.dart:291`（`service.enqueue` 无 try 包裹）。
- 现象：B5 只修了 PDF 分支（`_importPdf` 末尾 `:449` 进 try/catch + `enqueue` 调用点后收尾 `:294` 加兜底）。图片分支走完 EXIF 归一化后，`await _db.upsertCollectTask(task)`（`:359`，`importing → needBox`）仍是裸调用。写库失败时 `DatabaseException` 直接逃出 `enqueue`：本任务停在 `importing`（无失败标记、无法重试），同一批后面的文件不再处理，收集页的整批导入中断——与 SR-P1-4 原文描述的失败模式一字不差。B5-P1-DATA.md 遗留第 2 条自己记了这一处（“图片分支末尾的 `upsertCollectTask(needBox)` 也是 try 之外的同款形状”），但本次复核确认仍未修。
- 证据（探针 P-A，BEFORE UPDATE 触发器让一切写 `needBox` 的 UPDATE 失败，`enqueue(['test/fixtures/photo.jpg'])`）：
  ```
  DatabaseException(ffi sqlite_error 1811 ... simulated write failure ...
    Causing statement: UPDATE collect_tasks SET ... status = ?, ... needBox, 100 ...
    WHERE id = ?, parameters: task-1794686494182-0-594890, photo.jpg ...)
  ```
  `enqueue` 直接抛错，未返回失败任务。同一触发器下 PDF 分支能正常返回 failed 任务（既有测试 `import_service_p1_fixes_test.dart` 已钉住），图片分支不能。
- 修的方向：与 PDF 分支同款——图片尾部 upsert 包进 try/catch，失败走 `_failAndClean`（或至少在 `enqueue` 每文件循环外包一层 try，把异常转成该任务的 failed 行并继续下一个文件）。
- 严重度：**P1**（与 SR-P1-4 同级、同失败模式）。

### SR2-DATA-2 — SR-P1-4 未修完：`_failAndClean` 自身的写库无兜底，9 处调用点只有 1 处有保护
- 位置：`lib/services/import_service.dart:463-474`（`_failAndClean`，`:472` 的 `await _db.upsertCollectTask(failed)` 无 try）；调用点 `:380`、`:382`、`:386`、`:389`、`:392`、`:406`、`:424`、`:426`、`:430`（`_importPdf` 内全部早期失败返回）与 `:452`（尾部，唯一有 try/catch 的一处）。
- 现象：`_failAndClean` 是全部失败路径的公共出口，但它自己的 upsert 失败即抛错。只有尾部路径（`:451-459`）包了 `try { return await _failAndClean(...) } catch (_) { return _failed(...) }`；其余 8 处早期返回（读页数失败、加密/损坏、0 页、超 20 页、空间不足、渲染失败）都是裸 `return _failAndClean(...)`。库坏到 failed 行也写不进去时，异常逃出 `_importPdf`——而 `enqueue` 里 `final done = await _importPdf(...)`（`:287`）本身不在 try 里，只有它后面的收尾 upsert 有兜底——于是异常继续逃出 `enqueue`，整批中断、任务卡 `importing`。B5 报告称“再失败也只返回内存里的 failed 任务”，该保证只对尾部路径成立。
- 证据（探针 P-B：BEFORE UPDATE 触发器让一切写 `failed` 的 UPDATE 失败；假 PDF 引擎抛 `PdfCorruptException`；`enqueue` 应返回 1 个 failed 任务，实际直接抛错，5 个探针中 P-B 失败）。
- 修的方向：`_failAndClean` 内部把 upsert 包进 try，失败时返回内存里的 `_failed(task, error)`（目录已删，任务行写不进是预期内的降级）；或在 `enqueue` 的 `_importPdf` 调用点包 try/catch。
- 严重度：**P1**（与 SR-P1-4 同失败模式；触发条件比 SR2-DATA-1 更苛刻——需失败路径 + 写库同时失败，故列在后）。

### SR2-DATA-3 — B5 转交的 SR-P2-3 修法引入新丢数据：详情页重框事务失败时删掉题的唯一一份切片
- 位置：`lib/modules/detail/question_detail_page.dart:361-368`（写盘）与 `:382-396`（失败处理）。
- 现象：重框先把新裁切片原地写到 `sliceRel = ImportService.sliceRelative(q.id)`（`import_service.dart:65`：`'slices/$questionId.png'`，与旧切片同一文件路径，无临时名、无旧文件备份），再调 `replaceQuestionBoxesAndSlice` 事务。事务失败时 catch（`:393-394`）删掉 `sliceAbs`——删的正是刚覆盖掉旧图的唯一一份切片。库内 `slice_path` 仍指向该路径，题从此无图，详情页走“图片缺失”。修前（B5 之前）：事务失败只留“新图配旧框”的错配，图还在、框还能看；修后：图直接没了，且无任何恢复入口（切片只能重框再生，但重框页本身依赖页图，不依赖切片——仍可重框一次恢复，代价是一次人工重框；若页图也不在则彻底无法恢复）。
- 证据（代码直接可读）：`:368` `await File(sliceAbs).writeAsBytes(crop.png)` 原地覆盖；`:384-391` 事务调 `replaceQuestionBoxesAndSlice`，失败进 catch；`:393-394` `if (file.existsSync()) await file.delete()`。`_confirmSplit` 的同款清理（`collect_page.dart:568-573,676-682`）删的是新题 id 的新文件，无此问题——只有详情页是“同路径覆盖旧文件”。
- 修的方向：切片先写临时文件（如 `slices/<qid>.tmp-<随机>.png`），事务成功后再 rename 到正式路径；或失败时不删文件（留错配图由孤儿清理兜底，也比删唯一副本好）。注意 `evictCachedFileImage(sliceAbs)`（`:373`）在事务前已清缓存，改临时名后缓存失效点也要相应后移。
- 严重度：**P1**（B5 引入的回归；触发需事务失败，罕见，但一旦触发即丢唯一图片文件）。

---

## P2

### SR2-DATA-4 — 全行 REPLACE 快照写覆盖库内新值：`setReviewJoinedInto` 会把 `review_count` 打回旧值
- 位置：`lib/data/db_questions.dart:29-33`（`setReviewJoinedIntoImpl`，`_toRow(q.copyWith(reviewJoined: joined))` + `ConflictAlgorithm.replace`）；同款：`lib/data/db_questions.dart:144-148` 经 `repository.dart:saveRemedy` → `upsertCauseRecord`（整行 REPLACE）；`lib/data/repository.dart:toggleFavorite/archive/save` → `upsertQuestionIntoImpl`（`db_questions.dart:177-183`，同款 REPLACE）。
- 现象：`review_count` 是库内唯一用 SQL `+1` 递增的字段（`db_questions.dart:155`），内存里的 `Question` 对象不感知它。一次自查把库内 `review_count` 从 5 加到 6 后，任何一路拿着旧快照（`reviewCount: 5`）的全行 REPLACE 都会把它打回 5。`setReviewJoinedInto` 是 B5 新包进事务的写路径（SR-P2-8），事务化修了“题行 + 错因记录不同步”，但没修“整行覆盖”——旧快照问题原样进了新事务版。同理：`saveRemedy` 的 `upsertCauseRecord` 会用旧快照覆盖并发自查改掉的 `status`/`solvedCount`/`recheckDate`（复习页内是串行流程，实际难触发；跨页/跨会话的旧 `Question` 对象经 `toggleFavorite`/`archive`/`save` 走同一 REPLACE 路径则可达）。
- 证据（探针 P-C，内存库实测）：题 `review_count=5` → `recordSelfCheckInto(result: 'solved')` 后库内为 6 → 持 `reviewCount: 5` 的旧快照调 `setReviewJoinedInto(db, stale, true)` → 库内变回 `Expected: <6> / Actual: <5>`。
- 修的方向：状态类写操作按列 UPDATE 而不是整行 REPLACE（`setReviewJoined` 只改 `review_joined` 列；`toggleFavorite`/`archive` 同理）；`saveRemedy` 只改 `remedy_history` 列；或写前重读库内行再合并。`review_count` 本身只应由 SQL `+1` 改，任何 `_toRow` 整行写都不应带它。
- 严重度：**P2**（`reviewCount` 目前无页面渲染，用户侧暂不可见；但属于静默写坏已存数据，且一旦将来渲染题级复习次数即暴露。非 B5 引入，复审发现）。

### SR2-DATA-5 — `upsertFolder` 整科同名把关非原子：并发写入可绕过，库里出现两个同名文件夹
- 位置：`lib/data/db_catalog.dart:465-482`（先 `await folderNameExistsInSubjectFrom` 判重，再 `insert ... ConflictAlgorithm.replace`，两步都在事务外）；`folders` 表无 `UNIQUE(subject_id, name)` 约束（`db_schema.dart:126-129`）。
- 现象：B5 称 `upsertFolder` 是“最后一道防线”，但判重与写入之间有 await 间隙，两路并发同名写入可同时通过判重、先后插入成功。单用户单进程 UI 下正常操作是串行的，实际触发需两处入口同时写（如组织页与详情页各新建同名文件夹、或测试/后台任务并发），概率低；但“防线”本身不是防线——它防不住它声称要防的情况。
- 证据（探针 P-D）：`Future.wait` 同时调两次 `upsertFolder`（同科同名 `试卷`，id `f-a`/`f-b`）→ 库里同名行 `Expected: <1> / Actual: <2>`。
- 修的方向：判重 + 插入包进同一 `db.transaction`；或给 `folders` 加 `UNIQUE(subject_id, name)`（需先处理旧库已存在的重名行，建表是 `CREATE TABLE` 无迁移路径——新库从空开始，可直接改 DDL；或插入改 `ConflictAlgorithm.fail` + 捕获后转“已经有了”）。
- 严重度：**P2**（触发概率低；与 SR-P2-36 的“把关”宣称不符）。

### SR2-DATA-6 — SR-P2-4 校验仍放过空字符串主键：`id: ''` 的备份可恢复入库
- 位置：`lib/data/db_backup.dart:137-147`（`_validateBackupRow`：TEXT 主键只查 `row['id'] is! String`；`settings` 的 `key` 同款 `:138`；必填列 `:152-164` 只查 null 与类型）。
- 现象：`''` 是合法 `String`，通过全部校验；SQLite 的 TEXT PRIMARY KEY 允许空串，恢复后库里出现 `id: ''` 的学科/题/文件夹（`_iconFor('')` 等下游按空 id 走，未必立刻报错，但属于脏数据）。同理必填 String 列（`name` 等）为空串也放行。B5 的 P2-4 修法只堵了“缺键 / null / 类型错”，未堵“空串”。
- 证据（探针 P-E）：`subjects: [{id: '', name: '数学', color: 1}]` 的备份 JSON 调 `validateBackupData`，应抛错而实际通过（`Expected: throws anything / Actual: returned <null>`）。
- 修的方向：TEXT 主键与必填 String 列要求 `isNotEmpty`（`id`/`key`/`name`/`title`/`subject_id` 等）；空串即按“损坏的备份”拒绝。
- 严重度：**P2**（需恶意或损坏的备份才触发；校验缺口本身是 P2-4 的宣称范围）。

### SR2-DATA-7 — `readZip` 不拒重名条目：同名条目两次进位，第二次 rename 失败被误报成“文件写不进去”
- 位置：`lib/services/zip_archive.dart:202-252`（`readZip`，中央目录逐项校验条目数/偏移/名/方法/尺寸，但不检查重名）；`lib/data/db_backup.dart:437-457`（进位循环：同名条目的 staging 文件第二遍写入覆盖第一遍，第一遍已 `rename` 走，第二遍 `staged.rename(dest.path)` 因源文件不存在抛 `FileSystemException`）→ `:470-476` 的 catch 把它归为“恢复失败：文件写不进去，原题库没动”。
- 现象：重名 zip 是结构损坏的备份，应报“备份已损坏”；实际报磁盘问题，用户会被误导去查磁盘空间。数据本身不丢（失败时 `movedIn`/`backedUp` 回滚已跑，库未动——`importBackupJsonInto` 在进位之后才调），只是文案与定性错误。`backup.json` 重名是例外：恢复取最后一个（`readBackupJsonFromZipImpl` 与 `importBackupZipIntoImpl` 均取最后一条），进位循环又跳过它，不触发本问题。
- 修的方向：`readZip` 内按名判重，重名即抛 `ZipFormatException`；或恢复入口在写 staging 前校验条目名唯一。
- 严重度：**P2**（仅文案误导 + 损坏备份定性错误，无数据丢失；`buildZip` 不产重名包，需手工构造或第三方工具才触发）。

### SR2-DATA-8 — SR-P2-10 防呆口径不一致：`confirmSplitInto` 的框回填仍用 REPLACE 且不去重
- 位置：`lib/data/db_collect.dart:396-412`（题的框逐行 `txn.insert(... ConflictAlgorithm.replace)`，无去重）；对照：同函数题/拆分任务已改先查 + `fail`（`:381-412`），保留任务草稿有 `seenIds` 去重（`:515-518`）。
- 现象：同一题的 `boxesByQuestionId[q.id]` 里若有两个同 id 框（调用方构造失误或重复传入），后者静默覆盖前者，不报错——与 P2-10“重复确认显式失败而不是静默覆盖”的修法方向不一致。正常流程走不到（`collect_page.dart:592` 构造时每框 id 唯一，`normalizeBoxEditorInputs` 也去重），且框 id 碰撞概率在 SR-P2-12 熵加大后可忽略；残余的是“同一入参内重复 id”这一纯调用方失误口子。
- 修的方向：主路径复用保留任务的 `seenIds` 去重（重复 id 直接跳过或显式抛错）；或框插入改 `ConflictAlgorithm.fail`。
- 严重度：**P2**（低；正常流程不可达，属防呆口径未统一）。

### SR2-DATA-9 — SR-P2-5 估算不含 staging 临时占用：估算放行、恢复仍可能因盘满中途失败
- 位置：`lib/data/db_backup.dart:389-410`（`estimatedBytes = usedBytes - replacedBytes + incomingBytes`，与 `_maxRestoreBytes` 比较）；`:424-457`（先把文件解到 `.restore-staging-<时间戳>` 再进位）。
- 现象：恢复峰值占用是 `usedBytes + incomingBytes`（staging 里的副本与原文件共存），而估算只算恢复后占用 `usedBytes - replacedBytes + incomingBytes`。例：现有 1.5GB、备份带 0.9GB 文件、其中 0.5GB 会覆盖旧文件 → 估算 1.9GB 放行，峰值 2.4GB；目标盘剩余空间不足时 staging 写一半失败，走回滚 + “恢复失败：文件写不进去”。数据不丢（回滚已验证），但一次估算口径说“能恢复”的备份实际恢复失败，且失败文案不提空间。
- 修的方向：估算改用峰值口径（`usedBytes + incomingBytes`，或至少在 staging 写之前按峰值再判一次剩余空间）；或 staging 写失败时文案区分“空间不足”。
- 严重度：**P2**（低；需接近 2GB 的库 + 所剩盘空间不足才触发；数据安全不受影响）。

---

## 新增测试质量：只测 happy path 的用例

以下用例只钉住了成功路径或单点失败，未覆盖同组内对应的负向/边界分支。文件名与用例名逐条列出：

1. `test/b5_p2_data_test.dart`，SR-P2-5 组——`'现有占用超 2GB 时拒绝整个恢复，原库不动'` 与 `'现有占用 1GB 时恢复放行（对照）'`：两个用例的 zip 都只有 `backup.json`、无任何文件条目，`incomingBytes` 与 `replacedBytes` 全程为 0。估算公式里“解压后总字节累加”“将被覆盖文件的抵扣”“恰好 2GB 边界（`>` 拒、`==` 放行）”三个分支零覆盖。SR2-DATA-9 的估算缺口正在这些分支里。
2. `test/b5_p2_data_test.dart`——**SR-P2-6 无任何用例**：`_isRestoreStagingDir` 的严格匹配（`.restore-staging-backup` 用户目录不动）与 zip 恢复三档文案（`BackupRestoreException` 原样抛 / `DatabaseException` →“备份数据有问题” / 其余 IO →“文件写不进去”）在全仓测试里零覆盖。B5-P2-DATA.md 称“P2-6（staging 严格匹配 + DB 失败文案）”已测，与事实不符（`p3_backup_migration_test.dart` 只覆盖 zip 往返、路径穿越、缺 `backup.json`、版本过高四项）。修法本身经代码核对是对的，但无回归保护。
3. `test/import_service_p1_fixes_test.dart`，`'收尾 upsert 失败：enqueue 不抛、任务失败、整批继续'`：触发器只拦写 `needBox` 的 UPDATE，且只走 PDF 路径。图片分支尾部（SR2-DATA-1）与 `_failAndClean` 自身写库失败（SR2-DATA-2）无用例——这两个正是 P1-4 残留的口子。
4. `test/b5_p2_data_test.dart`，SR-P2-16 组——只有 `'两次基于同一旧快照的“已解决”：计数 +2，不是 +1'` 与 `'复查通过不加计数：库内 solvedCount 不动，只顺延复查日'`：`'unsure' 不写库`（含“无行时返回传入值”分支）、`'未解决' solvedCount 清 0`、无行时按传入值写库三分支无用例。
5. `test/b5_p2_data_test.dart`，SR-P2-15 组——`'拆分任务行还指着原目录：目录保留'` 与 `'无人引用：目录删掉（对照）'`：任务 id 均用无下划线的 `'orig'`，`_likeEscape` 的 `_`/`%` 转义分支无用例（生产任务 id 是 `task-<毫秒>-<序号>-<随机>`，不含 `_`，风险低）。
6. `test/detail_page_test.dart`，`'重新框选 §1.5.1'` 组——只有成功路径（两处 `'已重新框选，切片已更新'`）；SR-P2-3 转交的失败删切片分支（`question_detail_page.dart:382-396`）无用例，且该分支本身有 SR2-DATA-3 的问题。
7. `test/b5_p0_1_orphan_test.dart`——三用例覆盖 `pages/page-001.png`、`page-002.png` 与 `page-normalized.png`，未覆盖旋转烘焙页图 `pages/page-<p>-r<角度>.png`（与前者同属 `pages/` 枚举口径，风险低，但它是 P0-1 派生文件的另一类）。
8. `test/b5_p2_data_test.dart`，SR-P2-12 组——`'随机段 16 位十六进制，1000 个不碰撞'` 只断言格式与 1000 个不碰撞；碰撞后 REPLACE 静默覆盖的行为本身无用例（与 SR2-DATA-8 同根；熵加大后概率可忽略）。

反向说明（已覆盖负向/边界的用例，不列为缺口）：SR-P2-1（他科不动）、SR-P2-2（`recent_tasks` 与 `review_state` 行不动、队列清掉）、SR-P2-4（缺表/主键 null/必填列缺失与类型错/插库包装四项）、SR-P2-7（三项：标记重定向/不存在拒绝/标记失败回滚设置）、SR-P2-8（触发器失败回滚、空错因返回 false）、SR-P2-9（触发器失败回滚）、SR-P2-10（重复题/重复拆分任务显式失败且旧数据不动）、SR-P2-11（v1 全删/v2 不动/目录型 `-wal` 探针拒绝）、SR-P2-14（任务不存在抛错回滚/空列表键清页 + 缺页键保留）、SR-P2-17（含 `_` 的文件夹 id 不误筛）、SR-P2-36（同科跨层拒绝/跨科放行/自更新放行/改名撞名拒绝/预检 helper）、SR-P1-3（删后置空/中途失败整体回滚/删不存在的不抛错）、SR-P1-2（保留任务 + 未框页草稿 + 旋转角同事务建出）。

---

## 遗留：`reviewCount` 核实

- 所在位置：`questions.review_count` 列（`db_schema.dart:121`，`INTEGER NOT NULL DEFAULT 0`）；模型 `Question.reviewCount`（`models.dart:288` 默认 0、`:326` 字段、`:357/394` `copyWith`）；编解码 `_toRow`（`db_codec.dart:72`）与 `_fromRow`（`:105`）；备份表清单含 `questions`，恢复时随行携带。
- 写路径（全仓唯一）：`recordSelfCheckIntoImpl` 内的 `UPDATE questions SET review_count = review_count + 1 WHERE id = ?`（`db_questions.dart:155`），在自查事务内与改记录、记历史同事务；`'unsure'` 不写库也不加计数。无任何其他写路径（`upsertQuestion`/`setReviewJoinedInto` 不主动改它，但会经整行 REPLACE 把旧值写回去，见 SR2-DATA-4）。
- 读路径：**无任何页面渲染**。全仓唯一引用是 `question_detail_page.dart:268` 的 `reviewCount: base.reviewCount`（构造副本时原样带上，非展示），以及测试里的种子值。学习报告、复习页、错题本、详情页均不显示题级复习次数。结论与 B5-SUMMARY 的遗留口径一致：只存库、无页面渲染；是否显示需另立产品决定。本次不另立编号，已在 SR2-DATA-4 中记了它会被旧快照 REPLACE 打回的写坏风险。

---

## 已核实干净（逐项一句话）

- SR-P0-1：孤儿扫描已补任务派生口径——`page-normalized.png` 固定加引用，`pages/` 下实际文件逐个枚举（含旋转烘焙图同目录），任务 id 含分隔符时跳过；3 个新测试通过；备份导出共用同一口径，修后未拆分任务页图进备份。
- SR-P1-1：`reviewBucketOf()`/`isReviewDue()`（`repository.dart:40-53`）为唯一谓词——`dueToday`、首页焦点卡拆分、`subjectCounts` 三处同源，封面 `toReview + toRecheck = dueToday` 题数（新测试 4/4）；复习页 `:233/:239/:648` 的 `status != solved || isRecheckDue` 是按错因算的会话内谓词、与按题算的桶不冲突；错题本 `_causeStatusOf` 是按题的状态 pill 展示（复查优先于待解决，HTML 口径），不参与封面计数。
- SR-P1-2：保留任务重建已在 `confirmSplitIntoImpl` 同一事务（删原任务 → 插保留任务同 id → 写回未框页草稿，含旋转角；inners 按键里页码全量取），`collect_page.dart:571-620` 确认前构造、随拆题一起提交，事务外两步重建已删；新测试 2/2（保留任务 + 未框页 2 层草稿 + 旋转角同事务建出）。
- SR-P1-3：`deleteExamFromImpl`（`db_catalog.dart`）两步包进 `db.transaction`，`name=''` 已删（全仓只剩注释提及）；新测试 3/3（删后置空/中途失败整体回滚/删不存在不抛错）。
- SR-P1-4：PDF 分支已修——`_importPdf` 末尾 upsert 进 try/catch 走 `_failAndClean`（`:449`）、`enqueue` 调用点后收尾 upsert 加兜底（`:294`）；但图片分支与 `_failAndClean` 自身仍有口子，见 SR2-DATA-1、SR2-DATA-2。
- SR-P1-10+11：报告 `_questionsInRange`（`report_page.dart:178-185`）已加 `isOrganized && !isArchived`，弱点 Top5（原因组 `:190`、知识点组 `:218`）与学科分布（`:468-472`）同走该口径；两组计数均按 `questionIds: Set<String>` 去重（`:205/:237`），同名不同题各算 1 道。
- SR-P2-1：`deleteSubjectFromImpl` 事务内先按该科任务 id 删 `question_boxes`（草稿 + layer-2 子框同带 `collect_task_id`），再删任务行；测试覆盖他科不动。
- SR-P2-2：`clearDemoDataFromImpl` 改走 `_deleteQuestionTxn`（框/解决记录/自查历史/任务指向/复习队列一并清）；`review_state` 不再整行删（演示题只从队列摘掉，测试断言队列变 `[]`、行保留）；`recent_tasks` 不动。
- SR-P2-3：数据层事务本身无问题；详情页转交部分已落地 try/catch 删切片，但修法本身引入 SR2-DATA-3 的新问题。
- SR-P2-4：校验已补 13 表缺键即拒、主键 null 拒（自增 id 缺失允许）、必填列 + 类型校验、插库残余异常统一包成 `BackupRestoreException`；两处钉住旧行为的既有测试已按新口径更新；残余空串主键口子见 SR2-DATA-6。
- SR-P2-5：`importBackupZipIntoImpl` 恢复前估算（现有占用 − 将被覆盖的文件 + 解压后总字节），超 2GB 拒绝整个恢复，文案含现有/恢复后字节数；`_maxRestoreBytes` 与 `ImportService.maxStorageBytes` 同值 2GB；JSON 恢复不产生新文件，不适用检查；`readZip` 4GB 上限不变；残余 staging 峰值口径见 SR2-DATA-9。
- SR-P2-6：catch 已分三档（`BackupRestoreException` 原样抛 / `DatabaseException` →“备份数据有问题” / 其余 IO →“文件写不进去”），staging 清理已改严格匹配 `_isRestoreStagingDir`；但零测试覆盖，见“新增测试质量”第 2 条。
- SR-P2-7：`setCustomDataDirectory` 已认 `testMarkerDirectory`、先校验（空串/不存在拒绝）、先写设置后写标记、标记失败回滚设置；三项测试通过。
- SR-P2-8：`setReviewJoinedIntoImpl` / `syncCauseRecordsIntoImpl` 题行 + 错因记录同事务；`_seedCauseRecordsFor` 参数已放宽为 `DatabaseExecutor`；空错因加入仍返回 false；残余整行 REPLACE 快照覆盖见 SR2-DATA-4。
- SR-P2-9：`saveSettingsIntoImpl` 一个事务批量 replace，中途失败整体回滚（触发器测试通过）。
- SR-P2-10：`confirmSplitInto` 事务内先查同 id 题/拆分任务是否存在（存在抛 `StateError`），插入改 `ConflictAlgorithm.fail`；保留任务同 id 先删后插是刻意设计；残余框回填 REPLACE 见 SR2-DATA-8。
- SR-P2-11：先删 `-wal`/`-shm`（失败静默跳过），再删主库；只有主库删失败才抛错重试；附属删失败分支 Linux 无法模拟、Win11 真机复核仍待。
- SR-P2-12：随机段 8 位 → 16 位十六进制（64 位熵），格式仍为 `box-<scope>-p<page>-<16hex>`；1000 个不碰撞测试通过。
- SR-P2-13：`demoQuestions()` 已删除，全仓只剩注释与旧文档提及；`demoExams()`/`demoKnowledgePoints()` 仍在 `_seed` 里用。
- SR-P2-14：旋转角 update 影响 0 行时抛 `StateError` 回滚；缺页键保留旧草稿已写明为调用方契约并由测试锁定；唯一调用方修框编辑器 `_currentDraft` 保留空列表键（删空某页仍留键），契约实际成立。
- SR-P2-15：`_deleteTaskDirIfUnreferenced` 已补查 `collect_tasks.source_path LIKE 'imports/<taskId>/%'`，`_likeEscape` 转义 `_`/`%`/`\`；拆分任务引用时目录保留、无人引用时删除两用例通过。
- SR-P2-16：`recordSelfCheckIntoImpl` 事务内先读库内当前行再重算（`solvedCount` 在当前值上递增、复查通过不加计数、`remedyHistory`/`joinedAt` 以库内值为准、无行时才按传入值写），返回实际写库的记录；同一旧快照两次自查计 +2 的测试通过。
- SR-P2-17：`_deleteFolderTxn` 每层按 `folder_ids LIKE '%"id"%'` 在 SQL 层粗筛（`"` 定界、`_likeEscape` 防通配符），再内存精筛；含 `_` 的文件夹 id 不误筛测试通过。
- SR-P2-22 数据层部分：保留任务重建已在 SR-P1-2 收进同一事务；收集页剩余的失败删本次新建切片/烘焙图已落地（`collect_page.dart:568-573` 裁剪失败、`676-682` 事务失败，均按 `writtenRels` 清单删）。
- SR-P2-36 数据层部分：`folderNameExistsInSubjectFromImpl` 整科按名查（`excludeId` 排除自身），`upsertFolder` 增加整科同名把关（抛 `StateError`“已经有了”）；页内三处预检属错题本工人范围；残余并发绕过见 SR2-DATA-5。
- SR-P2-68：`readZip` 已改走中央目录（EOCD 定位、逐项校验、数据描述符按中央目录尺寸读、解压前 `rawSize` 预判、无文件条目抛错、ZIP64 与多盘拒绝）；残余重名条目见 SR2-DATA-7。
- 路径安全（回归抽查）：`resolveDataPath` 默认拒绝对路径（`allowAbsolute` 只出现在测试）；`_deleteDataFileIfUnreferenced` 只接受 `slices/` 前缀；`_deleteTaskDirIfUnreferenced` 先验 taskId 安全字符集；备份路径校验与 zip-slip 校验到位；`_resolveInsideDir` 越界返 null。
- 事务边界（回归抽查）：`_deleteQuestionTxn`、`deleteFolderFromImpl`、`deleteSubjectFromImpl`、`deleteCollectTaskFromImpl`、`replaceQuestionBoxesAndSliceIntoImpl`、`saveReviewState`/`loadReviewState`、`clearReviewState` 均无新引入的事务外多步写；`saveSettingsIntoImpl`、`setReviewJoinedIntoImpl`、`syncCauseRecordsIntoImpl`、`deleteExamFromImpl`、`confirmSplitIntoImpl` 均为本次 Batch 5 新增/改动的事务化入口，无事务嵌套（sqflite 不支持嵌套，递归处均传 `Transaction`）。

## 附注

- 文档残留（非数据层问题，转文档组）：`docs/decision-log.md:36` 仍写 `demoQuestions()`“仅作定义保留”，但函数已在 SR-P2-13 删除；D-04 的同款补注（B5 文档阶段写）亦已过时。
- 本报告只列复核确认的问题；“已核实干净”清单所列各项均经代码对照或测试复跑验证，未只信 B5 报告自述。
