# 数据层最终自审报告（SELF-REVIEW-DATA）

- 日期：2026-11-14
- 范围：`lib/data/database.dart`、`db_paths.dart`、`db_schema.dart`、`db_storage.dart`、`db_codec.dart`、`db_questions.dart`、`db_catalog.dart`、`db_collect.dart`、`db_orphans.dart`、`db_settings.dart`、`db_backup.dart`、`repository.dart`、`demo_data.dart`、`badge_notifier.dart`；另读 `docs/ui-replication/B4-DATABASE.md`、`B3-SUMMARY.md`；为核实调用关系只读了 `lib/services/import_service.dart`、`lib/services/zip_archive.dart`、`lib/modules/collect/collect_page.dart`（`_confirmSplit`）、`lib/modules/detail/question_detail_page.dart`（重框段）、`lib/modules/settings/settings_page.dart`（孤儿清理段）、`lib/models/models.dart`（`CauseRecord.isRecheckDue`）。
- 方式：逐文件通读 + 脚本核对 B4 拆分前后 API + `flutter analyze lib/data/`（`~/workspace/flutter-install/flutter/bin/flutter`，**No issues found**）。未跑任何测试，未改任何代码，未动演示库；收工核对 `~/.local/share/quiz-master2/quiz-master2.db` md5 仍为 `8f7f9c64405dc6e484ac2bf8e5e1a807`（v1、9 题）。
- 结论：**共 22 条：P0 1 条，P1 4 条，P2 17 条。** 无 P0 级“已发生的丢数据”，但 P0-1 是常规操作可达的误删路径，应先修。

---

## P0（常规操作可达的错删 / 丢数据）

### P0-1 孤儿扫描把未拆分 PDF 任务的页图（及 EXIF 归一化页图）当孤儿，设置页一键清理会删掉它们
- **位置**：`lib/data/db_orphans.dart:9-36`（`_referencedRelativePaths`）、`:39-64`（`scanOrphanFilesFromImpl`）；调用链 `lib/modules/settings/settings_page.dart:167-209`（开数据组即扫描，弹窗确认后删扫描列表全部文件）。
- **现象/后果**：引用口径只收 `questions.source_path / page_image_path / slice_path` + `collect_tasks.source_path`。一个未拆分的 PDF 任务，`source_path` 只是 `imports/<id>/original.pdf`，而渲染出的页图在 `imports/<id>/pages/page-001.png`（`lib/services/import_service.dart:65-66` `renderedPageRelative`、`71-79` `pageImageRelativeForTask`），没有任何行引用——扫描会把全部页图列为孤儿。设置页文案还承诺“题目和数据不动，删了找不回来”，用户一点确认，任务的页图全灭；修框页按“页图缺失明确报错、不开编辑器”处理，且没有重新渲染的入口，任务只能删掉重导，框选进度（草稿框还在库里，但无页图可框）实际作废。同理，图片任务的 EXIF 归一化副本 `imports/<id>/page-normalized.png`（`import_service.dart:52-53`）也没有任何行引用（修框页是按文件存在性解析它的，`import_service.dart:75-78`），也会被当孤儿删掉（此处有回退到原图，影响较小）。
- **复现/证据**：导入一个多页 PDF、不拆题 → 设置 → 数据组 → 孤儿扫描列表里出现 `imports/<taskId>/pages/*.png`。代码上可直接判定：`_referencedRelativePaths` 从不按 `collect_tasks` 的任务 id 展开 `imports/<id>/pages/` 目录，也没有任何“任务存续即引用”的规则。
- **修的方向**：引用口径补两条——（a）所有 `collect_tasks` 行的 `imports/<taskId>/` 整个目录视为被引用（或至少 `pages/` + `page-normalized.png` + `original.*`）；（b）或扫描时跳过仍有存续任务的目录。修后补单测：建一个 needBox 的 PDF 任务（只有 `source_path`，无题），扫描结果必须为空。

---

## P1（正确性 bug / 非事务多步写 / 计数错误）

### P1-1 错题本封面“要复习”与首页“要复习”口径不一致：复查到期的题在封面不计入要复习
- **位置**：`lib/data/repository.dart:66-80`（`dueToday`）vs `:105-136`（`subjectCounts`）。
- **现象/后果**：`dueToday`（首页焦点卡、`homeRevCounts` 用）算 `r.status != solved || r.isRecheckDue`；`subjectCounts`（错题本封面三数用，`wrongbook_page.dart:154`）的 `toReview` 只算 `rs.any(status != solved)`。一道题全部错因已解决、但有一条到了复查时间：首页算“要复习”，封面 `toReview` 为 0、`toRecheck` 为 1、`solved` 为 0（`!rs.any(isRecheckDue)` 把它排除出已解决）。同一道题在两个入口数字打架，用户会以为封面或首页其一算错了。`isRecheckDue` 的定义（`models.dart:137-144`：已解决且复查日 ≤ 今天）已核实，复查到期只发生在已解决记录上，所以这不是边界重叠，是 `subjectCounts` 漏了复查分支。
- **复现/证据**：任一题加入复习 → 全部错因两次“已解决” → 复查日改到今天 → 首页要复习数含它，错题本封面要复习数不含它。
- **修的方向**：`subjectCounts` 的 `toReview` 改为与 `dueToday` 同口径（`status != solved || isRecheckDue`）；或反过来明确“封面要复习不含复查”并同步改首页——以既定口径为准，两处必须同一表达式，最好抽成一个共享谓词。

### P1-2 确认拆题：事务只包库内四步，未框页的“保留任务重建”在事务外，崩溃窗口丢任务 + 丢未框页草稿
- **位置**：`lib/data/db_collect.dart:382-430`（`confirmSplitIntoImpl`，事务内删原任务全部草稿框 `:424`）+ `lib/modules/collect/collect_page.dart:569-616`（`_confirmSplit`：`confirmSplit` → `saveCollectTask(retained)` → `saveDraftBoxes(...)`，三次独立写库）。
- **现象/后果**：`confirmSplitInto` 无条件删掉原任务所有 `question_id IS NULL` 的草稿框（包括未框页的），然后调用方在事务外按同 id 重建保留任务并写回未框页草稿。`confirmSplit` 提交成功、重建还没发生时进程被杀/崩溃：原任务行已删、草稿框已删，保留任务不存在——未框页连同页图目录引用一起丢（页图文件还在盘上，但没有任务行指向它们，之后还会被孤儿清理当孤儿删掉，见 P0-1）。即使不崩溃，`saveDraftBoxes` 抛错也会留下“任务在、草稿丢”的半截状态。
- **复现/证据**：多页 PDF 只框部分页 → 确认拆题 → 在 `confirmSplit` 返回后、`saveCollectTask` 前杀进程（代码走读可判定窗口存在：三段之间无任何事务/补偿）。
- **修的方向**：首选把“删原任务 + 建拆分任务 + 重建保留任务 + 写回未框页草稿”做进同一个 `confirmSplitInto` 事务（把 `unboxedPages` 草稿与保留任务行作为参数传进去）；退而求其次：`confirmSplitInto` 只删已确认页的草稿框，不删未框页的，调用方重建失败时草稿仍在。

### P1-3 `deleteExam` 三步写不在事务里，且第一步是无意义的 `name=''`
- **位置**：`lib/data/db_catalog.dart:436-447`（`AppDatabaseCatalog.deleteExam`，extension 方法，无 `Impl` 版）。
- **现象/后果**：`update exams set name=''` → `delete exams` → `update questions set exam_id=null`，三段顺序 await、无事务。中间失败/崩溃会留下两种半截状态：试卷已删但题还指着已不存在的 `exam_id`（悬空引用；错题本按试卷筛题时这批题丢过滤）；或试卷还在但名字被清空成 `''`（学科管理里出现无名试卷）。第一步 `name=''` 没有任何作用——下一秒行就被删掉，纯属死步骤，疑似复制粘贴残留。
- **复现/证据**：代码直接可读；与同文件的 `deleteTagFromImpl`（`db_catalog.dart` 内事务版）、`deleteKnowledgePointFromImpl`、`deleteChapterFromImpl` 对比，只有 `deleteExam`（与 `renameExam`、`renameChapter` 等单步写不同，它是三步）没包事务。B3 遗留点 3“`deleteExam` 是否包事务”核实结果：**不包，属实**。
- **修的方向**：删掉 `name=''` 那行，剩余两步包进 `db.transaction`（仿 `deleteTagFromImpl` 的写法，最好顺手补一个 `deleteExamFrom` 可单测版）；调用方 `repository.dart:287`、`subjects_page.dart:285` 不用动。

### P1-4 `_importPdf` 末尾成功路径的 `upsertCollectTask(done)` 在 try 之外，写库失败会逃出 `enqueue`
- **位置**：`lib/services/import_service.dart:403`（`_importPdf` 内最后的 `upsertCollectTask(done)`）；调用点 `:267-273`（`enqueue` 内 `final done = await _importPdf(...); await _db.upsertCollectTask(done);`，无 try 包裹）。
- **现象/后果**：读页数、渲染两个 try 都有兜底 catch（`:337-352`、`:371-386`），但渲染成功后写 `needBox` 状态这一步不在任何 try 里。此时若写库失败（磁盘满、库损坏、DB 锁），异常直接逃出 `enqueue`：本任务停在 `importing` 状态（页图已渲染完却无 `needBox` 行，界面无失败标记、无法重试），且同一批后面的文件不再处理，异常抛到调用方（收集页）层面。B3-SUMMARY 遗留点 3 核实结果：**属实**。触发概率低（只在写库恰好失败时），但失败模式是“卡死 + 整批中断”，不是“单个任务失败”。
- **修的方向**：`_importPdf` 末尾的 upsert 包进 try/catch，失败走 `_failAndClean`（或至少返回 failed 任务）；或 `enqueue` 的 `_importPdf` 调用点加 try/catch，把异常转成该任务的 failed 行并继续处理下一个文件。

---

## P2（完整性风险 / 边界 / 死代码 / 可维护性）

### P2-1 删学科漏清草稿框：`deleteSubjectFrom` 不删该科任务的 `question_boxes` 草稿行
- **位置**：`lib/data/db_catalog.dart:17-52`。
- **现象/后果**：事务内删题（经 `_deleteQuestionTxn`，只清 `question_id` 指向该题的框）→ 删 `collect_tasks` → 删 `recent_tasks`/`folders`/`knowledge_points`/`subjects`，但从不删 `collect_task_id` 属于这些任务、`question_id IS NULL` 的草稿框（含其 layer-2 子框）。删学科后库里永久残留指向已删任务的孤儿框行。行本身不再被任何查询读到（`boxesForTask` 按任务 id 查，任务已删），属惰性膨胀 + 违反“删学科清干净”的预期；若将来按 `collect_task_id` 做统计/清理会踩到。
- **修的方向**：事务内先按该科任务 id 集合删 `question_boxes where collect_task_id IN (...)`（或在删 `collect_tasks` 前对每任务调已有逻辑），补单测：建学科 + 任务 + 草稿框 → 删学科 → `question_boxes` 为空。

### P2-2 清演示数据绕开删题事务：`clearDemoDataFrom` 不清框、不置空任务指向、还全清 `recent_tasks`
- **位置**：`lib/data/db_settings.dart:19-54`。
- **现象/后果**：事务内只删演示题的 `cause_records`/`review_history`、整行 `review_state`、**全部** `recent_tasks`、演示题行。缺三样：（a）不删演示题的 `question_boxes`（与 `_deleteQuestionTxn` 不一致）；（b）不把 `collect_tasks.question_id` 指向演示题的行置空，留下悬空指向；（c）`recent_tasks` 只有 id=1 一行，清掉它会连非演示的“最近任务”一起抹掉，与注释“非演示数据一律不动”矛盾。现实中演示题通常没有框/任务（`_seed` 不预置演示题，`db_schema.dart:230` 起），所以实际影响小，但这是三处删题入口中唯一不走 `_deleteQuestionTxn` 的。
- **修的方向**：复用 `_deleteQuestionTxn` 删演示题（或至少补删其框、置空任务指向）；`recent_tasks` 只清指向演示题的行（或不动它）。

### P2-3 详情页重框：新切片先写盘，事务失败残留孤儿切片（B3 遗留点 6，属实）
- **位置**：`lib/modules/detail/question_detail_page.dart:347-366`（`writeAsBytes` 在 `:354`，`replaceQuestionBoxesAndSlice` 在 `:366`）；`lib/data/db_collect.dart:298-324`（事务本身没问题）。
- **现象/后果**：切片文件在事务前写盘；事务因题不存在（`updated != 1` 抛错，`db_collect.dart:318-320`）或其它 DB 错回滚时，新切片文件已落盘、无任何行引用。无数据不一致，只有孤儿文件，孤儿清理可回收。B3 遗留点 6 核实结果：**属实，影响仅限孤儿文件**。
- **修的方向**：事务失败时调用方删刚写的切片文件；或先写临时名、事务成功后再改名。低优先级。

### P2-4 备份校验有缺口：缺表按空表静默清空、主键可为 null、不校验必填列
- **位置**：`lib/data/db_backup.dart:35-80`（`validateBackupDataImpl`）、`:103-141`（`importBackupJsonIntoImpl`）。
- **现象/后果**：（a）`validateBackupDataImpl` 只强制 `subjects`/`questions` 为数组，其它表键缺失时 `rows == null → continue`，而恢复是“清表再插回”——一份缺了 `cause_records` 的备份恢复后会**静默清空全部错因记录**，用户无从察觉；（b）只查 `row.containsKey('id')`，`id: null` 也能通过，插库时才抛 NOT NULL 错误；（c）不校验必填列/类型（如 `questions` 缺 `title`/`subject_id`），非法行在恢复事务中途才抛原生 `DatabaseException`，而不是 `BackupRestoreException`，设置页展示的是原始 sqlite 文案。事务本身保证了“要么全进要么全不进”，所以是“校验不充分 + 报错不友好”，不是半截库。
- **修的方向**：校验层补三条：全部 13 张表键缺失即拒绝（或明确提示缺表按空处理并让用户确认）；`id`/`key` 非空；每表必填列存在且类型正确。插库异常统一包成 `BackupRestoreException`。

### P2-5 备份恢复绕过 2GB 存储上限；zip 导入上限是 4GB 不是 2GB
- **位置**：`lib/data/db_backup.dart:185`（`readZip` 默认 `maxTotalBytes = 4GB`）、`:217-297`（`importBackupZipIntoImpl` 全程无容量检查）；对照 `lib/services/import_service.dart:40-41,218-227,355-366`（2GB 上限只在 `enqueue` 导入路径执行）。
- **现象/后果**：§6 第 9 条定的 2GB 上限只在“导入文件”时拦。恢复一个 3GB 的 zip 备份会直接把库撑过 2GB，无任何提示；恢复 JSON 备份同理（只恢复行，不恢复文件时不超，但 zip 恢复带文件）。与既定决定不一致。
- **修的方向**：`importBackupZipIntoImpl` 在文件进位前估算（现有占用 − 将被覆盖的文件 + 解压后总字节），超 2GB 拒绝整个恢复；或至少在恢复成功后提示已超上限。

### P2-6 zip 恢复：DB 失败时错误文案误导；旧 staging 清理不校验时间戳
- **位置**：`lib/data/db_backup.dart:240-297`。
- **现象/后果**：（a）catch 里一律包成“恢复失败：文件写不进去，原题库没动”——但 `importBackupJsonInto` 抛出的 DB 错误（如 P2-4 的非法行）也会走这条文案，用户会被误导去查磁盘而不是备份文件内容；（b）开头的旧 staging 清理只认前缀 `.restore-staging-`（`:248`），不像迁移的 `_deleteStaleMigrationStaging`（`db_storage.dart:233-249`）那样校验纯数字时间戳，数据目录下一个同名用户目录会被误删。两处都是小口径。
- **修的方向**：区分 `BackupRestoreException`（原样抛）与 DB 异常（文案写“备份数据有问题”）；staging 清理复用 B2-5d 的严格匹配。

### P2-7 `setCustomDataDirectory` 忽略测试隔离钩子，且先写标记文件后写设置
- **位置**：`lib/data/db_paths.dart:130-137`；对照 `lib/data/db_storage.dart:319`（`migrateToDirectory` 用 `testMarkerDirectory ?? _defaultDataDirectoryPath()`）。
- **现象/后果**：该方法直接写 `_defaultDataDirectoryPath()` 下的 `db_location.txt`，不认 `testMarkerDirectory`——测试调它会改真实标记文件（B3-P02 测试隔离的口子）；且先写标记、再 `saveSetting('databaseLocation', ...)`，后者失败时标记已换、下次启动就用新目录，与设置里记录的位置不一致；另对 `dir` 无任何校验（空串/不存在的路径照写，好在空串会被 `dataDirectoryPath` 的 `isNotEmpty` 兜住）。
- **修的方向**：标记目录改为 `testMarkerDirectory ?? _defaultDataDirectoryPath()`；先校验目录可写、顺序改为先写设置后写标记（或失败时回滚标记）。

### P2-8 `setReviewJoined` / `syncCauseRecords` 多步写不在同一事务
- **位置**：`lib/data/repository.dart:36-57`。
- **现象/后果**：`setReviewJoined` 先 `upsertQuestion(reviewJoined: true)`，再 `ensureCauseRecords`（逐条 insert）；中间抛错/被杀，题已标“已加入复习”却没有一条 `cause_records`。`dueToday`（`repository.dart:66-80`）对无记录的题返回 false、`subjectCounts` 跳过它——题从复习计数里静默消失，用户以为已加入、实际永远排不到。`syncCauseRecords` 同样是“全表读 + 逐条删 + `ensureCauseRecords`”三段分离，中间失败会留下“旧错因记录已删、新错因记录未补”的半截状态。
- **修的方向**：数据层加一个事务版（如 `setReviewJoinedInto(db, q, joined)`），题行 + 错因记录同事务；`syncCauseRecords` 同理。

### P2-9 `saveSettings` 逐条写设置，无事务
- **位置**：`lib/data/db_settings.dart:137-141`（循环调 `saveSetting`，每次独立 insert）。
- **现象/后果**：设置是相互独立的键，单条失败只影响该键，不丢题；但一次“保存全部设置”中途失败会留下新旧混杂的设置组合（如主题已换、字体未换）。影响小。
- **修的方向**：包进一个 `db.transaction` 批量 replace。

### P2-10 `confirmSplitInto` 用 REPLACE 静默覆盖已存在的题/拆分任务
- **位置**：`lib/data/db_collect.dart:382-430`（`txn.insert(..., ConflictAlgorithm.replace)`，题 `:394`、拆分任务 `:415`）。
- **现象/后果**：若同 id 的题已存在且已整理（`is_organized=1`、已有解决记录），重复确认会把它覆盖回未整理的全新题，而旧的 `cause_records`/`review_history` 还挂在这个 id 上——已治愈的记录贴到了一道“新题”上。UI 层有 `_splitPagesFor` 防重复拆（`collect_page.dart:633` 起），所以正常流程走不到这里；但数据层没有任何防呆（与 `_deleteBoxesForQuestionTxn` 特意防“两个 layer=1 框”的谨慎不一致）。
- **修的方向**：题与拆分任务改 `ConflictAlgorithm.fail`（或先查存在即抛错），让重复确认显式失败而不是静默覆盖。

### P2-11 `deleteLegacyDatabaseIfPresent` 主库删完、附属文件删失败才抛错
- **位置**：`lib/data/db_schema.dart:51-89`（`:81-88` 先 `file.delete()`，再删 `-wal`/`-shm`，后者失败抛 `LegacyDatabaseException`）。
- **现象/后果**：主库已删、抛错称“删除失败，下次启动重试”——下次启动文件已不存在，会直接建空库，所谓“重试”不存在；更糟的是残留的旧 `-wal` 会留在新库旁边（新库建在同一路径时，SQLite 按 salt 校验一般会忽略不匹配的 WAL，但属于“删一半留一半”的脏状态）。老库本来就是要整体删除的（§6 第 1 条，已定），所以不是误删数据，是错误处理与文案不一致。
- **修的方向**：先删 `-wal`/`-shm` 再删主库；或附属文件删失败只记日志不抛错（主库已删即算删除成功）。

### P2-12 `newBoxId` 只有 32 位随机熵
- **位置**：`lib/data/db_paths.dart:69-79`（8 位十六进制，`Random.secure()`）。
- **现象/后果**：同一 `(scope, page)` 下 8 hex = 32 位，框数上千时碰撞概率进入可感知区间（生日悖论约 7 万个框 50%）；而 `saveDraftBoxesInto`、`_replaceBoxesTxn`、`confirmSplitInto` 插框全用 `REPLACE`——碰撞会静默覆盖另一道框，不报错。现实框量（每页个位数、每任务数十）下概率极低。
- **修的方向**：随机部分扩到 12-16 位十六进制，或插框前查 id 是否已存在（存在则重生成）。

### P2-13 `demoQuestions()` 无生产调用方，且内部 4 道题“已加入复习但未整理”
- **位置**：`lib/data/demo_data.dart:5-236`（定义），调用方：全仓无（`demoExams()`/`demoKnowledgePoints()` 仍在 `db_schema.dart:260,267` 的 `_seed` 里用）。
- **现象/后果**：9 道演示题中 q-math-2（`:31`）、q-eng-2（`:69`）、q-pol-1（`:126`）、q-pol-3（`:162`）写了 `reviewJoined: true` 却没写 `isOrganized: true`（默认 false）。这违反“未整理的题没有加入复习入口”的模型（`repository.dart:36-44` 的 `setReviewJoined` 本身不拦，但 UI 只给已整理/已归档题加入口）；若将来有人重新启用演示题加载，这 4 道题会被 `dueToday`（要求 `isOrganized`）排除，看似加入、实则不复习。死代码本身 P0B2 报告已记过（“现无调用方，仅定义保留”），本次复核确认仍无调用方。
- **修的方向**：要么删掉 `demoQuestions()`（`_seed` 明确不预置演示题，§6 第 1 条），要么把它 4 道题的 `isOrganized` 补 true 并加一条“演示题加载后复习计数正确”的测试。

### P2-14 `saveDraftBoxesInto`：任务行不存在时旋转角静默丢失；缺页键保留旧草稿
- **位置**：`lib/data/db_collect.dart:228-285`（旋转角 update 在 `:269-277`，无影响行数检查）。
- **现象/后果**：草稿保存是“删该页旧框 → 插新框 → 写 `page_rotations`”同事务；若任务行已被删（`update` 影响 0 行），框照样写进去了（成孤儿草稿），旋转角却丢了——调用方无从得知。反向：某页框被清空后，若调用方传的 `boxesByPage` 里根本没有该页的键（而不是空列表），该页旧草稿不会被删，残留。两处都是“调用方契约无校验”，不是已发生的 bug。
- **修的方向**：旋转角 update 影响 0 行时抛错回滚；文档注明“被清空的页必须传空列表键”。

### P2-15 `_deleteTaskDirIfUnreferenced` 不查 `collect_tasks.source_path`
- **位置**：`lib/data/db_collect.dart:131-155`（只查 `questions.source_path / page_image_path LIKE 'imports/<taskId>/%'`）。
- **现象/后果**：拆分任务的 `source_path` 指向原任务目录（`imports/<原任务id>/original.pdf`，`collect_page.dart` 拆分任务构造）。删原任务时，若拆出题已全删、但拆分任务行还在，目录会被删，拆分任务行继续指着不存在的原文件。目前拆分任务不直接读 `source_path` 对应的文件（`_splitPagesFor` 只做字符串比对），所以实际影响≈0；但检查口径与函数注释“没有任何题还指向该目录”之外的任务引用存在缺口。
- **修的方向**：补查 `collect_tasks.source_path LIKE 'imports/<taskId>/%'`，有引用就不删目录。

### P2-16 `recordSelfCheck` 按传入快照算新值，无乐观并发保护
- **位置**：`lib/data/repository.dart:149-205`（`updated` 完全由传入的 `r.solvedCount`/`r.status` 推导，`db_questions.dart:22-48` 的事务本身没问题）。
- **现象/后果**：两处自查若基于同一份旧 `CauseRecord` 先后提交，后提交的会覆盖先提交的计数（如两次快速点“已解决”，`solvedCount` 都按旧值 +1，本应 +2 只 +1）。UI 是串行操作，实际难触发；但数据层没有“按当前库内值递增”的防呆。
- **修的方向**：事务内先读库内当前 `cause_records` 行再算，或 `review_count`/`solved_count` 用 SQL `+1`（`recordSelfCheckInto` 里 `review_count` 已是 `+1` 写法，`solvedCount` 可仿效）。

### P2-17 （补充）`_deleteFolderTxn` 每层递归全表读题
- **位置**：`lib/data/db_catalog.dart:82-118`（每次递归 `txn.query('questions')` 全表 + `_fromRow` 逐行解码）。
- **现象/后果**：文件夹嵌套删除时时间复杂度 O(层数 × 题数)，题库上千时删文件夹会明显变慢。正确性无问题，纯性能。
- **修的方向**：按 `folder_ids` 在 SQL 层过滤（JSON 字段可用 `LIKE '%"id"%'` 粗筛再内存精筛），或一次读全表后内存递归。

---

## B3 遗留点核实结论

| B3-SUMMARY 遗留点 | 核实结果 |
|---|---|
| 3. `_importPdf` 末尾 `upsertCollectTask(done)` 在 try 之外 | **属实**，见 P1-4（`import_service.dart:403`，调用点 `:267` 无 try） |
| 6. 详情重框事务前写盘可能残留孤儿切片 | **属实**，见 P2-3（`question_detail_page.dart:354` 先写盘，`:366` 再调事务；仅孤儿文件） |
| `deleteExam` 是否包事务 | **不包，属实**，见 P1-3（`db_catalog.dart:436-447` 三步无事务，另有无意义的 `name=''`） |
| 1. 模型文件未被 `.gitignore` 忽略 | 数据层外事项，未核实（不在本次审的 14 个文件内） |
| 2. 红色无框警告范围（新导入任务也警告） | 数据层外事项，未核实 |
| 4. `CompactSliceThumb` 无 `errorBuilder` | widgets 层事项，未核实 |
| 5. 叠加层多框取第一个、无确定性优先级 | widgets/整理页事项，未核实 |
| 7. 整理队列确认框非路由级弹窗等 | 整理/详情页事项，未核实 |
| 8. 边界文档旧描述 | 文档事项，未核实 |
| 9. 误杀 flutter_tester 进程 | 过程事项，无残留影响（本次 `flutter analyze` 正常跑完） |
| 10. organize P1-1 对照用例偶发失败 | 未复现（本次未跑测试） |

---

## 已定事项（只记一笔，不算新问题）

- **v1 库直接删除**（`db_schema.dart:51-89` `deleteLegacyDatabaseIfPresentImpl`，`openAtImpl`）：Meng 已定（§6 第 1 条），老库整体删、不迁移。已知接受风险：用户若用旧版应用积累了 v1 数据，升级后数据全失且无提示备份。代码实现与决定一致（损坏到读不出版本时拒绝删除、拒绝打开，是保守的）。
- **多值字段 JSON**（`db_codec.dart:14-88`）：`folder_ids` 等 5 列 + `remedy_history` + `review_state.queue` 统一走 `encode/decodeStringList`，无裸 `join(',')`/`split(',')` 残留；读到非法值按 `[]` 处理（§3.3 已定，无老数据兼容负担）。
- **存储上限 2GB**：只在导入路径执行（`import_service.dart:40-41,218-227,355-366`），备份恢复路径绕过，见 P2-5。
- **老收集任务删除**（`db_collect.dart:45-81`）：删任务删未整理拆出题、已整理题保留，符合 Meng 2026-11-14 的定稿；实现上单任务只通过 `collect_tasks.question_id` 找一题，与拆分任务 1:1 的结构一致。
- **备份含文件 zip**（`db_backup.dart:147-164` 导出、`217-297` 恢复）：JSON + `imports/`/`slices/` 被引用文件；缺文件不进包、恢复后走“图片缺失”，与决定一致。

---

## B4 拆分完整性核实（`database.dart` → 10 个 part 文件）

- **接线**：`database.dart` 有 10 条 `part` 声明，10 个 part 文件各有且仅有 `part of 'database.dart'`；`flutter analyze lib/data/` **No issues found**（本次独立重跑）。
- **API 对照**（脚本比对拆分前原文件 `~/workspace/demo-db-backup/database-before-b4/database.dart.before-b4`）：56 个公开静态转发全部存在，签名逐字一致，无新增、无遗漏；旧文件 89 个静态成员中 31 个 `_` 私有静态已全部在 part 文件里找到且仅一次顶层定义（含 `_toRow`/`_fromRow`/`_causeFromRow`/`_collectTaskFromRow`/`_questionBoxFromRow` 等 6 个行映射，以及 `_deleteQuestionTxn`、`_deleteFolderTxn`、`_replaceBoxesTxn`、`_deleteBoxesForQuestionTxn` 等事务内 helper）；`deleteOrphanFilesImpl` 等记录类型返回值的 `Impl` 也已确认存在（`db_orphans.dart:68`）。实例方法（67 个 extension 方法）无遗漏、无重名。
- **行为**：转发只改函数体为 `=> <name>Impl(...)`，实现体原文搬移；`backupTables` 等 4 个常量移到类首集中声明，文本不变；删掉的仅 3 行分隔注释。未发现重复定义、遗漏导出或转发签名漂移。
- **小注**：B4 报告称“公开 API 核对：新增成员 0 个”——脚本复核一致；但 `setCustomDataDirectory`（`db_paths.dart:130`）仍是直接写默认标记目录，与 `migrateToDirectory` 的 `testMarkerDirectory` 钩子不一致，见 P2-7（这是拆分前就存在的问题，不是拆分引入的）。

---

## 审过且干净的地方（抽查结论）

- **路径安全（B3-P01）**：`resolveDataPath` 默认拒绝对路径，`allowAbsolute: true` 全仓只有测试用（`test/b3_p01_path_safety_test.dart:79`）；`_deleteDataFileIfUnreferenced`（`db_collect.dart:91-102`）只接受 `slices/` 前缀；`_deleteTaskDirIfUnreferenced`（`:131-155`）先验 taskId 安全字符集；备份路径校验（`db_backup.dart:82-100`）与 zip-slip 校验（`zip_archive.dart:43-60` `validateZipEntryName`，`readZip` `:218` 逐条目校验）均到位；`_resolveInsideDir` 越界返 null。
- **删题/删文件夹事务**：`_deleteQuestionTxn`（`db_questions.dart:92-118`）一次事务清错因记录、自查历史、任务指向、复习队列、框（含先删子框）、题行；`deleteFolderFromImpl`（`db_catalog.dart:60-80`）整棵子树同事务，提交后才删无引用切片；`deleteSubjectFromImpl`（`:17-52`）同事务删题/任务/文件夹/知识点/学科（仅 P2-1 的草稿框缺口除外）。
- **自查三步同事务**：`recordSelfCheckIntoImpl`（`db_questions.dart:22-48`）改记录 + 记历史 + `review_count + 1`，角标提交后才 bump。
- **重框换框 + 切片同事务**：`replaceQuestionBoxesAndSliceIntoImpl`（`db_collect.dart:298-324`）题不存在时抛错回滚（仅 P2-3 的写盘时序缺口除外）。
- **迁移 staging + 原子替换 + 回滚**：`migrateDataFilesImpl`（`db_storage.dart:35-229`）复制→校验文件数/字节→`.old` 备份→同盘 rename→失败回滚；`migrateToDirectory`（`:271-345`）标记文件是提交点，写标记失败回滚；B2-5b“目标只有孤儿文件时 `overwrite=false` 下 rename 失败返 failed”是代码注释里已声明的已知边界，未修但无丢数据。
- **建库/回退收窄**：`_openDb`（`database.dart` 内）只有主位置无库文件时才回退安装目录 `data/`，已有库损坏时明确抛错不静默建空库；`onDowngrade` 抛错提示用新版打开。
- **编解码**：JSON 多值字段收口完整；`decodeQueue` 只认 `{q, c}` 对象，自定义错因含 `,`/`|` 不会切错；`_collectTaskFromRow` 的 `page_rotations` 非法时按 `{}` 处理。
- **排序防 regression**：`upsertSubject`/`insertExamInto`/`insertKnowledgePointInto`/`upsertCollectTaskInto` 均为 UPDATE-first，避免 REPLACE 顶行乱序；`allTagsFrom`/`allExamsFrom`/`allKnowledgePointsFrom`/`allSubjects` 显式 `rowid` 排序。
- **备份导出**：只打包被引用的文件；`exportBackupJsonFrom` 用 `jsonEncode`（手写转义漏控制字符的问题已修）；`importBackupJsonInto` 整个恢复在事务内，失败不留半截库。
- **复习队列断点**：删题时 `_removeFromReviewQueueTxn`（`db_questions.dart:69-90`）同步清队列项；`position` 越界由复习页 `review_page.dart:265` 的 `clamp` 兜底。
- **角标**：`bumpBadgeVersion` 只在状态变化类写操作后调（`badge_notifier.dart` 全文件 7 行）；进度高频更新不 bump（`db_collect.dart` `upsertCollectTask` 的状态比对节流）。
- **`question_boxes` 唯一约束**：`idx_boxes_one_layer1_per_question` partial unique（`db_schema.dart`）防一题两个 layer-1 框；`confirmSplitInto` 重填前先删旧框。
- **`demo_data.dart` 的 `demoExams()`/`demoKnowledgePoints()`** 仍在 `_seed` 里正常用；`presetFolders`/`presetTags` 正常。
