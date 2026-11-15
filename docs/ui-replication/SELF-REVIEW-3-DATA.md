# 第三次自审 · 数据层（DATA）

- 范围：只审第六批改动，不审全量代码。只审、不改代码；未提交、未推送。
- 基线：`6448c45`（Batch 5）→ `38cbc4b`（Batch 6，已推远端）之间的差分；工作树与远端 Batch 6 一致（本地另有未提交改动与本审阅无关，审阅以两提交间差分为准）。
- 审阅文件：`lib/services/import_service.dart`、`lib/data/db_backup.dart`、`db_catalog.dart`、`db_questions.dart`、`db_collect.dart`、`lib/models/models.dart`、`lib/services/zip_archive.dart`、`test/import_service_p1_fixes_test.dart`、`test/b5_p2_data_test.dart`、`test/b5_p0_1_orphan_test.dart`（另为核对 SR2-12 跑了 `test/b5_p2_services_test.dart`，为核对 SR2-16 跑了 `test/p1_schema_backup_test.dart`、`test/s8b4_backup_migration_test.dart`）。
- 方法：差分走读 + 探针测试（临时文件，跑完已删）+ 单文件串行跑测试（`--concurrency=1`，`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`）。
- 结论：P0 0 项；P1 1 项；P2 7 项。编号 DATA-1～DATA-8。

## DATA-1（P1）：SR2-17 的重名拒绝可被路径写法变体绕过，恢复仍误报“文件写不进去”

- 位置：`lib/services/zip_archive.dart:221-224`（`readZip` 的 `seenNames` 判重）；`lib/data/db_backup.dart:447-462`（进位循环）。
- 现象：`readZip` 只按条目名的原始字符串判重。`slices//q1.png` 与 `slices/q1.png`（或 `slices/./q1.png` 与 `slices/q1.png`）在文件系统上是同一文件，判重却放行；恢复走到进位循环时，第二遍 `staged.rename(dest.path)` 因源文件已被第一遍 rename 走而抛 `FileSystemException`，恢复入口把它归为“文件写不进去”——正是 SR2-17 声称已消除的误报（“不再走到进位循环误报‘文件写不进去’”）。
- 证据（探针实测，Linux，临时测试已删）：
  - `readZip(buildZip([('slices//q1.png', …), ('slices/q1.png', …)]))` 不抛错，返回两个条目；`slices/./q1.png` 变体同样不抛错。
  - 端到端 `importBackupZipInto`（backup.json + 上述两条目）：抛 `BackupRestoreException: 恢复失败：文件写不进去，原题库没动`——错误文案与 SR2-17 的新测试（`b5_p2_data_test.dart:1623`，断言含“已损坏”且不含“文件写不进去”）所锁定的行为正好相反。数据库未动（恢复仍被安全拒绝），损害限于误诊：用户会被引向“清理磁盘空间”而不是“备份已损坏，请重新导出”。
  - 根因链：`validateZipEntryName`（`zip_archive.dart:51`）不拒空段（`//`）与 `.` 段；`readZip` 存的是原始名；staging 写盘与进位都按原始名拼路径，POSIX 下 `//` 与 `/./` 折叠成同一文件。
  - 同根因、Windows 上才可达的变体（未在 Linux 探针复现，代码分析）：大小写变体（`Slices/Q1.png` vs `slices/q1.png`，Windows 大小写不敏感）与反斜杠变体（`slices\q1.png`——校验时 `\`→`/` 放行，存名仍带 `\`，Windows 下拼路径即同一文件）。产品跑在 Windows 上，这两类与 `//`/`.` 是同一缺口。
  - 自家写出方无此问题：`exportBackupZipFromImpl`（`db_backup.dart:245`）用 `Set`（`_referencedRelativePaths`）去重后排序写出，不产生重名条目；触发须是第三方/手工拼出的 zip。
- 修的方向：在 `readZip` 里判重前先归一化条目名再比较：`\`→`/`、折叠连续 `/`、消解 `.` 段（与 `validateZipEntryName` 共用同一归一化函数）；如需覆盖 Windows 大小写变体，判重键再加小写折叠（仅用于比较，不改存名与落盘路径）。归一化后的键也可用于 staging/进位路径，避免同名变体在写盘阶段再次撞车。

## DATA-2（P2）：SR2-27 的 orderBy 未覆盖全部框查询

- 位置：`lib/data/db_collect.dart:182-186`（`boxesForQuestionFromImpl`）、`:210-214`（`boxesForTaskPageFromImpl`）。已覆盖的是 `boxesForTaskFromImpl:199` 与 `boxesForPageImageFromImpl:232/244`。
- 现象：两个框读查询仍无 `orderBy`。SR2-27 的处方是“框查询加 orderBy”，第六批只改了其中两处。
- 证据与影响面：经全仓 grep，两函数在生产代码里没有任何调用方——`repository.dart` 只暴露 `boxesForTask` / `boxesForPageImage`，UI 只调这两处；`boxesForQuestionFrom` / `boxesForTaskPageFrom` 只有 `database.dart:469/479` 的静态转发与测试在用（`p1_schema_backup_test.dart`、`p2_main_chain_test.dart`、`b3_p01_path_safety_test.dart`、`b5_p2_data_test.dart:954`）。因此当前无用户可见影响，属修法不彻底。
- 另：SR2-27 测试（`b5_p2_data_test.dart:722`）的注释称“题行本身也倒序插入，钉住题 id 列表的顺序”——实际上最终框顺序只由框查询的 `ORDER BY` 决定，题 id 列表的 `orderBy: 'id ASC'`（`db_collect.dart:232`）经该测试不可观测（它只影响中间 IN 列表，不影响输出顺序）。测试本身有效，注释有夸大。
- 修的方向：两处补 `orderBy: 'page ASC, id ASC'`（与 `boxesForTask` 同口径）；或如确认两函数已无生产用途，在注释里标明“仅测试用”，避免后人误以为已覆盖。

## DATA-3（P2）：`upsertCauseRecord` 被窄化为只改 `remedy_history`，名字与公开入口未同步

- 位置：`lib/data/db_questions.dart:348-375`（`upsertCauseRecord`，Batch 6 改）；`lib/data/repository.dart:66`（`saveCauseRecord`）。
- 现象：行已存在时 UPDATE 只写 `remedy_history` 一列；`status` / `solvedCount` / `recheckDate` / `lastCheck` 等字段的改动被静默丢弃（UPDATE 影响 1 行，不走 INSERT，无任何报错）。方法名仍是全量 upsert，`repository.saveCauseRecord` 仍是公开入口。
- 证据：当前生产调用方只有 `saveRemedy`（`repository.dart:235-241`，只改补救历史），故无现存生产影响；但 `saveCauseRecord` 在测试播种里被用（`test/b5_p1_1_subject_counts_test.dart:242`，走 INSERT 路径故不受影响）。将来任何想经它改状态的调用方都会静默丢数据——与 SR2-14 报告里“唯一生产调用方”的注释所依赖的前提（无调用方改状态）是口头约定，不是代码保证。
- 修的方向：二选一——(a) 把方法改名 `updateCauseRemedy`（并相应改 `saveRemedy` 的调用点），让窄化显性化；(b) 保留全量语义，另立 `updateCauseRemedy` 给 `saveRemedy` 用，`upsertCauseRecord` 恢复整行 UPDATE-first（仍不含 `review_count` 类问题——cause_records 无此类计数列，整行写无 SR2-14 同类风险，但须与 `recordSelfCheckIntoImpl` 的事务内重算口径协调）。无论哪种，加一个用例钉住：已存在行的 `status` 改动经 `saveCauseRecord` 后是被写入还是被丢弃，二者必居其一、不得静默。

## DATA-4（P2）：`_dedupKey` 的回退分支会让不存在的路径遮蔽真实文件；大小写折叠在 Linux 下合并真实不同的文件

- 位置：`lib/services/import_service.dart:176-190`（`_dedupKey`）、`:213`（`seenPaths`）。
- 现象（a，顺序依赖，Linux-only）：去重键在打开文件之前算。`resolveSymbolicLinks()` 对不存在的路径抛错，回退到“绝对路径小写”。不存在的大写拼写（如 `TEST/FIXTURES/PHOTO.JPG`）回退出的键，与真实文件解析出的键完全相同。若批次里不存在的拼写排在前面，它先被处理（复制失败→failed 任务），真实文件随后被当作重复跳过——用户只得到一个失败任务，真实文件从未导入。
- 证据：代码分析（键计算是确定性的）：不存在路径回退 `File(path).absolute.path.toLowerCase()`；存在文件 `resolveSymbolicLinks()` 后 `.toLowerCase()`，两者在 cwd 相同、大小写以外无差异时相等。现有用例（`import_service_p1_fixes_test.dart:395-431`）只覆盖 `[真实, 大写]` 顺序（真实在先），未覆盖 `[大写, 真实]` 顺序。Windows 上不存在此问题（两种拼写都打开同一文件）。
- 现象（b，注释已披露的取舍）：小写折叠对整条路径生效。Linux 下同目录仅大小写不同的两个真实文件（如 `IMG_001.JPG` 与 `img_001.jpg`）会被当成同一文件，后者静默跳过。报告与代码注释已说明这是“病态构造”且产品跑在 Windows 上；此处只记为已确认的语义取舍，未重复编号为新问题——但应注意它与 (a) 是同一行代码的两个面。
- 修的方向：按平台分流键的生成——可解析时用解析后路径（大小写折叠只在该分支做，Windows/macOS 的真实同文件仍去重）；解析失败（文件不存在）时回退键用原始路径（不折叠小写），让不存在的拼写不再与真实文件撞键。代价：Linux 下 `[真实, 不存在的大写]` 会建两个任务（一个 needBox、一个 failed），这是诚实行为，与 Windows 行为（一个任务）不一致但各自正确。另补 `[大写, 真实]` 顺序的用例。

## DATA-5（P2）：SR2-1 的 onProgress 兜底只包了尾部两次回调，循环内两处仍可抛错

- 位置：`lib/services/import_service.dart:310`（复制循环内 `onProgress?.call(id, pct)`）、`:535`（`_importPdf` 渲染回调内 `onProgress?.call(task.id, pct)`）。已包 try 的是 `:419`（90%）、`:449`（图片 100%）、`:572`（PDF 100%）。
- 现象：进度回调抛错时，复制循环的 catch 把它当成“文件复制不进去”（`:317-332`：删目录、failed 任务）；渲染回调的抛错被 `_importPdf` 的渲染 catch 接住（`:543-547`：`_failAndClean`，删目录、failed 任务“渲染这份 PDF 时出了问题”）。好文件因 UI 回调异常被判失败、目录被删；外层每文件兜底 try 能防止逃出 `enqueue`（整批继续），但救不回该文件。
- 证据：Batch 5 代码里这两处同样无保护（`git show 6448c45` 对照），属 Batch 6 修法覆盖不全而非新回归。收集页的回调（`collect_page.dart:297`）有 `mounted` 检查，触发概率低，但 `setState` 在 dispose 竞态等路径下仍可抛错。
- 修的方向：两处与尾部同款包 try/catch（回调抛错只吞掉，不翻转任务状态）；或在 `enqueue` 入口把 `onProgress` 包一层永不抛错的转发函数，一处修、五处受益。

## DATA-6（P2）：B6 报告里的三处数字与代码事实不符（行为本身无问题）

- (a) `b5_p2_data_test` 是 36→**56**，不是 36→55。`git show 6448c45` 计 36 个 `test(`，`38cbc4b` 计 56 个；新增用例名差分：新增 21 个名、改名（SR2-59）1 个，净增 20。B6-P2-DATA 的逐项表自求和也是 20（SR2-14 3 + SR2-15 1 + SR2-16 1 + SR2-17 2 + SR2-18/70 1 + SR2-58/65 2 + SR2-66 4 + SR2-67 3 + SR2-68 2 + SR2-27 1 = 20），只有标题句“新增 19 项 / 36→55”算错。本次实跑：该文件 56/56 通过。
- (b) `_failAndClean` 调用点是 **13 处**，不是报告与代码注释所说的 9 处。现文件 grep：enqueue 内 3 处（`:348` PDF 调用点兜底、`:443` 图片尾部、`:463` 外层兜底）+ `_importPdf` 内 10 处（`:496/498/502/505/508/522/540/542/546/568`），定义在 `:581`。Batch 5 是 10 处（`git show 6448c45` 计数）。数字虽错，实质无问题：守卫在函数内部，13 处调用点全部受益（见“已确认无问题”）。
- (c) `b5_p2_services_test` 的“15/15”是 A-import 运行时的文件规模（当时 14 项 + 新增 SR2-12 用例 1 项），D-services 随后往同一文件追加了 SR2-24/SR2-78 等分组；现文件共 25 项（18 个 `test(` + 7 个 `testWidgets(`），本次实跑 25/25 通过。报告数字按时间点无错，但作为终版总结的“文件通过数”已过时。
- 修的方向：三处数字在 B6-SUMMARY/B6-P1-IMPORT/B6-P2-DATA 里更正（报告文件，不改代码）。

## DATA-7（P2）：SR2-71“恰好 50MB PDF”用例间歇失败，未捕获到失败信息

- 位置：`test/import_service_p1_fixes_test.dart:344-352`。
- 现象：本次审阅中共跑该文件 9 次：前 3 次调用里失败 2 次（第 1 次组合跑的失败列表明确指向该用例；第 2 次组合跑只看到 `+75 -1`，未捕获到失败用例名），之后 7 次全部通过（3 文件组合 76/76 ×3、5 文件 103/103、单文件 16/16 ×2、单用例 ×1）。失败信息两次都未捕获，未能证实原因。
- 证据与分析：用例本身无产品逻辑可疑点——`List.filled(50MB, 0)` 真实写盘 50MB，`enqueue` 流式复制 50MB，假引擎渲染 1 页；50MB 恰等于上限，`size > limit` 不触发；`storageUsageBytes` 扫描的 `_tmp/imports` 当时约 20MB，远不到 2GB。最可能的是环境抖动（1.5 核共享 VM、/tmp 为 512MB tmpfs，50MB 真实分配+写盘+复制在负载高时撞上默认测试超时），但未经证实。不是产品 bug 的证据：同一用例随后 7 次通过，且 B6 门禁全量 852/852 通过。
- 修的方向：门禁重跑时留意该用例；如再现，保留完整失败输出再定性；可给两个边界用例（20MB 图片、50MB PDF）显式加 `timeout`，避免把环境抖动误读为回归。

## DATA-8（P2）：SR2-18 的去重集合按题/按页分作用域，跨题/跨页同 id 仍会被 REPLACE 静默覆盖

- 位置：`lib/data/db_collect.dart:484-499`（`seenBoxIds` 在 `for (final q in questions)` 循环内新建）与 `:556-565`（保留分支 `seenIds` 在 `for (final page in retainedPages)` 循环内新建）；插入均用 `ConflictAlgorithm.replace`，`question_boxes.id` 是 `TEXT PRIMARY KEY`（`db_schema.dart:186`）。
- 现象：同一框 id 若出现在两道题（或保留任务的两页）的入参里，第二处插入会 REPLACE 掉第一行（改写 `question_id`/`page`），第一题静默丢框——与 SR2-18/SR2-70 要堵的“静默覆盖”是同一模式，只是作用域换成了跨题/跨页。
- 证据与可达性：生产调用方（`collect_page.dart:545-643`）已按题分区——每 1 层框独占一道题（`:613` 直接赋值），独立题内框各挂唯一目标题（`:642-646` 追加一次），同一框对象不可能进两个列表；框 id 本身含页码（`box-<task>-p<页>-<uuid8>`），跨页同 id 须伪造 id。因此当前不可达，属纵深防御缺口而非现实 bug。
- 修的方向：把两个去重集合提到 `confirmSplitIntoImpl` 的事务级（一个 `seenBoxIds` 覆盖全部题 + 保留分支），跨题/跨页重复也跳过（保留第一个）；或把两处插入的 `ConflictAlgorithm.replace` 改为 `fail`，让越界重复显式抛错走事务回滚（与 SR-P2-10 的防呆口径一致）。

## 已确认无问题

- **`_failAndClean` 守卫真覆盖全部调用点**：函数内删目录与 upsert 均包 try（`import_service.dart:585-593`），`_failed` 是纯构造；13 处调用点（DATA-6(b)）全部受益，函数本身不抛。SR2-2 达成。
- **每文件兜底 try 覆盖完整**：从初始 importing upsert 到收尾的全部步骤都在 try 内；`continue` 不触发 catch；catch 内 `_failAndClean` 不抛，`taskAdded`/`cleanupDir` 两分支正确（未加行时 `tasks.add`，已加行时替换末尾）；`_dedupKey` 自身永不抛（内部分两级回退），try 外只有去重与任务构造两步无抛错点。
- **EXIF 两类失败区分正确**：`decodeError != null`（解不开/镜像方向）删目录、失败行 upsert 包 try、`continue`，绝不复活 needBox；`bytes == null` 或归一化/写盘失败走旧降级（原图在盘）；降级路径的 `onProgress(90)` / `_updateProgress(90)` 均已包 try。SR2-1(b) 达成。
- **“成功行卡 importing”无其他出口**：PDF 分支外层重写（`enqueue` 的 `upsertCollectTask(done)` 吞错）看似可疑，但 `_importPdf` 内部已先落库（成功 needBox 或 `_failAndClean` 的 failed），外层重写只是冗余；其失败不改变库内已落状态（Batch 5 代码对照，该 swallow 预先存在且无害）。图片分支尾部失败走 `_failAndClean`，与 PDF 同款。
- **逐列 UPDATE 无漏列**：`_toRow`（`db_codec.dart:59`）含 questions 表全部 28 列；`upsertQuestionIntoImpl` 的 UPDATE 除 `review_count`/`id` 外全写（`:184-191`），不存在时才整行 INSERT；`setReviewJoinedIntoImpl` 只写 `review_joined`（`:34-38`）；`review_count` 的唯一写路径是 `recordSelfCheckIntoImpl` 的 SQL `+1`（`:169`）与新行 INSERT 的初始值。SR2-14 的口径达成。
- **`upsertFolder` 同事务判重成立**：判重 SELECT 与插入在同一 `db.transaction` 内；生产是单例单连接（`database.dart:217` 缓存 `_dbFuture`，注释明确禁多连接），sqflite 串行化保证第二路事务看到第一路已提交的行；并发测试（1 路 ok + 1 路“已经有了”，`b5_p2_data_test.dart:1443`）本次实跑通过。无 UNIQUE 约束是事实，但生产拓扑下不构成缺口（见“已确认的遗留”）。
- **SR2-16 误拒面已实证排除**：UI 入口均拦空串（详情页标题空时回落原值 `question_detail_page.dart:251`；章节名与知识点名必填 `subjects_page.dart:390`）；全仓 grep 在 `test/` 与 `lib/` 的备份夹具里未发现空串必填列；本次实跑 `p1_schema_backup_test` 与 `s8b4_backup_migration_test` 全过（在 103/103 内）。自家导出的合法备份不会被新规则误拒。
- **`backup.json` 重名例外无冲突**：两处调用方都取最后一个（`importBackupZipIntoImpl:385`、`readBackupJsonFromZipImpl:304`），与 `readZip` 的例外一致；进位/写盘循环都跳过它。SR2-17 例外成立。
- **SR2-19 峰值口径如报告所说偏保守，且算式与 staging 模型精确一致**：`peakBytes = usedBytes + incomingBytes`；`backup.json` 不进 staging（`:440` 跳过），被覆盖文件挪进 `.overwritten/` 仍占盘，rename 不复制，故峰值确为现有占用 + 解压后总字节；“最终 <2GB 但峰值 >2GB 被拒”属实，见“已确认的遗留”。
- **SR2-18 同题去重与调用方一致**：`seenBoxIds` 每题新建、`seenIds` 每页新建；调用方已分区（见 DATA-8），同 id 跨题在生产路径不可达；SR2-70 用例（同题同 id 只留第一个）本次实跑通过。
- **`allCauses` 保序去重无副作用**：全部调用方（播种 `db_schema.dart:227`、同步 `db_questions.dart:62`、详情页展示与复习记录、报告页按错因计数）均按“每错因一次”语义使用；旧数据里的重复“其他”此前会在详情页重复显示、在报告里重复计数，去重只修这两处，无依赖重复的调用方。SR2-23 达成。
- **SR2-60/SR2-2/SR2-1 测试钉住行为**：`import_service_p1_fixes_test.dart` 16/16（多次运行）；`b5_p2_data_test.dart` 56/56；`b5_p0_1_orphan_test.dart` 4/4；`b5_p2_services_test.dart` 25/25。

## 已确认的遗留（B6-SUMMARY 已列，只确认、不重复编号）

- **失败行写不进库时，DB 任务仍卡在 `importing`**：属实。各失败分支的 upsert 包 try 后，写库失败只返回内存 failed 任务，库内行保持 importing；SR2-2 用例已把该状态钉住（库里 importing 行 1 条）。处方内降级行为。
- **SR2-12 需可注入时钟**：属实。20 次快速导入是最强非确定性覆盖；确定性同毫秒覆盖须重构 id 生成。
- **SR2-15 并发测试依赖 sqflite 事务串行化**：属实，且生产单连接拓扑下成立。补充说明：`folders` 表无 UNIQUE 约束，若将来出现第二连接，并发同名仍可双双插成功；当前无此路径。
- **SR2-16 fixture 影响面**：本次已用相关备份测试跑通（`p1_schema_backup_test`、`s8b4_backup_migration_test` 在 103/103 内），可视为已闭合；全量 852 本次未重跑，以门禁记录为准。
- **toggleFavorite / archive / save 未按仓库层逐列方法做**：属实。`repository.dart:253-293` 把调用方快照直传 `upsertQuestion`；`upsertQuestionIntoImpl` 的 UPDATE-first 只护住 `review_count`，旧快照的其余 26 列仍会覆盖库内新值——具体可达场景：详情页重框刚改了 `slice_path`，错题本旧快照点收藏即把 `slice_path` 写回旧值。另立项时再处理。
- **SR2-19 峰值口径偏保守**：属实（见“已确认无问题”）。最终占用 <2GB 但峰值 >2GB 的备份现在会被拒，需 Meng 定夺。
- **SR2-62 同毫秒场景未确定性覆盖**：属实（不在本次数据层范围，见 B6-P2-COLLECT）。
- **B6-P2-DATA 的“测试未跑”遗留**：本次审阅中相关文件已跑通（`b5_p2_data_test` 56/56、`b5_p0_1_orphan_test` 4/4、`import_service_p1_fixes_test` 16/16，另 `b5_p2_services_test` 25/25、两备份文件在 103/103 内）；工具链当时缺失的问题已不存在。

## 验证记录

- 探针：临时 `test/zz_probe_sr217_test.dart`（3 个用例：`//` 变体读包、`.` 变体读包、端到端恢复文案），跑完已删。结果：`readZip` 两变体均不抛错；端到端恢复报“文件写不进去”。（DATA-1 的证据）
- 测试运行（`--concurrency=1`，onnxruntime `LD_LIBRARY_PATH`）：
  - `test/b5_p2_data_test.dart` + `test/b5_p0_1_orphan_test.dart` + `test/import_service_p1_fixes_test.dart`：前两次调用各 75/76（SR2-71 恰好 50MB PDF 用例失败，见 DATA-7），之后 3 次组合跑 76/76。
  - 同三文件 + `test/p1_schema_backup_test.dart` + `test/s8b4_backup_migration_test.dart`：103/103。
  - `test/b5_p2_services_test.dart`：25/25。`test/import_service_p1_fixes_test.dart` 单文件：16/16（×2），单用例（50MB PDF）：通过。
- 未跑全量测试与 Linux Release 构建（门禁已有记录）。
