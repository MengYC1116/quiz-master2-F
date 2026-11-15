# B2 数据层收尾报告（items 1 / 4 / 5）

- 日期：2026-11-14
- 分支：`ui-replication`（未提交、未推送，按任务要求）
- 范围：只动 `lib/data/database.dart` + 新增测试
  `test/b2_leftover_data_test.dart`；没动其它产品文件，没动
  `repository.dart`，没改 DB schema 版本、无迁移、无 `onUpgrade`。
- 结论：item 1 已是事务化（见下）、item 4 与 5a/5d 已修、5b/5c
  按任务要求留原状并已锁定/验证。`flutter analyze` 0 问题；
  本批测试 17 项 + P0 文件 12 项 = 29 项通过；邻近 P3/P2 文件
  39 项通过。

## Item 1 — 四项多步写的事务

**核查结果：产品代码不用改。**任务描述写的是旧快照：当前工作区里
`renameTagFrom` / `deleteTagFrom` / `deleteKnowledgePointFrom` /
`deleteChapterFrom` 已全部用 `db.transaction` 包住多步写，实例方法
（`renameTag` / `deleteTag` / `deleteKnowledgePoint` /
`deleteChapter`）只是 delegate。已逐项核对四处实现，确认无遗漏。

补的测试（`test/b2_leftover_data_test.dart`，触发器模拟中途失败，
照 P0 加固测试的写法）：

| 测试 | 断言 |
|---|---|
| `renameTagFrom` 中途失败 | 标签行仍是旧名，题上的标签没变 |
| `deleteTagFrom` 中途失败 | 标签行还在，题上的标签没变 |
| `deleteKnowledgePointFrom` 中途失败 | 知识点行还在，题上的知识点没变 |
| `deleteChapterFrom` 中途失败 | 该章知识点行都在，题上的知识点没变 |

留原状：`deleteExam` 同样是三步写、无事务（先把名改空、再删行、
再把题的 `exam_id` 置空），与这四项同类，但任务只列了四项，本批
未动。建议下一批照同一模式补 `deleteExamFrom` + 原子性测试。

## Item 4 — tags / exams / knowledge_points 的 REPLACE + 无 ORDER BY

改动（`lib/data/database.dart`，照 `upsertSubject` / `upsertCollectTask`
的正面先例）：

- `insertExam` → 新 `insertExamInto(db, e)`：先 `UPDATE … WHERE id = ?`，
  影响 0 行时才 `INSERT`；实例方法 delegate。
- `insertKnowledgePoint` → 新 `insertKnowledgePointInto(db, kp)`：同上。
- `allTags` / `allExams` / `allKnowledgePoints` → 新
  `allTagsFrom` / `allExamsFrom` / `allKnowledgePointsFrom`
  （`ORDER BY rowid`，与 `allSubjects` 同一口径）；实例方法 delegate。
- `insertTag` 不用改：它用 `ConflictAlgorithm.ignore`，冲突时直接忽略，
  不删行、不改 rowid。
- 其它表的 REPLACE 未动（`upsertQuestion` / `upsertCauseRecord` 按
  §4.3 定稿保留；`upsertFolder` 的读方法有 `ORDER BY sort_order`，
  不属本项范围）。

测试（4 项）：改标签名顺序不变；同 id 再插试卷（改名+改日期）顺序
与 rowid 不变、新试卷插末尾；同 id 再插知识点顺序与 rowid 不变、
新知识点插末尾；`renameKnowledgePoint`（单步 UPDATE）改名顺序不变。

## Item 5a — 标记写失败留重复副本

改动（`lib/data/database.dart`）：

- `migrateDataFiles` 新增可选参数 `keepBackups` / `outBackups` /
  `outMoved`（默认 `keepBackups: false`，原有调用方行为不变）：
  为 true 时成功后不删 `.old` 备份，并把备份与新移入文件的路径报出来。
- 新增静态 `rollbackMigrationFiles(moved, backups)`：删刚移入的新文件、
  把 `.old` 移回；替换中途失败与写标记失败共用同一份回滚（原 catch 块
  的内联回滚已抽成调它）。
- `migrateToDirectory`：调 `migrateDataFiles` 时传 `keepBackups: true`；
  标记写成功后再删 `.old` 备份；标记写失败时调回滚（新位置复原，
  不留重复副本；旧位置与旧标记原地不动），目标目录是本次新建的且回滚
  后已空时顺手删掉。
- 新增 `@visibleForTesting static String? testMarkerDirectory`（与
  `testDataDirectory` 同一口径）：非空时标记写到这里而不是默认数据目录，
  测试才不会动真实标记文件。

测试（5 项）：`keepBackups` 成功后 `.old` 保留、路径报出；
`rollbackMigrationFiles` 后新位置复原（旧库旧图回来、新文件没了、
无 `.old` 残留）；`migrateToDirectory` 端到端三项（成功：标记写好后
`.old` 才删；标记写失败：返回 failed、新位置复原；标记写失败且目标
是本次新建的：回滚后目标目录也删掉）。

残留窗口（已接受）：标记写好、删 `.old` 之前崩溃，会在目标位置留下
`.old` 副本（旧数据、无丢失，应用仍用旧位置）。下次迁移不顺带清
`.old`——任务只要求清 staging（“其它一概不动”），故未扩。

## Item 5b — 目标只有孤儿文件、没有库（未修，现状锁定）

**留原状，原因：**

1. 完整修法需要产品口径：要么定“合并式迁移”（跳过已存在文件），
   方案只定了覆盖/保留/取消三选一，未定合并口径，不能自创语义；
2. 只改数据层也到不了对话框：覆盖对话框由设置页的
   `databaseExistsAt`（只认库文件）触发，`migrateDataFiles` 里把
   failed 改成 targetExists 只会把提示从“迁移失败，仍用原来的题库”
   换成“这个位置已经有题库了”——文案还是错的（那里没有库），用户也
   选不到覆盖。完整修法要动设置页预检与对话框，不在本批文件范围内。
3. 现状是安全的：返回 failed，目标原封不动、无数据丢失；用户清掉
   目标目录后可正常迁移。

测试锁定现状（1 项）：目标有 `imports/orphan/x.jpg`、无库，
`overwrite: false` → failed，孤儿文件字节不变、目标不产生库文件、
无 staging 残留。

测试中确认的一点：失败只在**源也有** `imports/` / `slices/` 要搬时
才发生（staging 的目录 rename 撞上目标已存在的同名目录）；源没有
这些目录时只搬库文件，迁移能成功，孤儿目录原地不动。测试已按
前一种情形（源也有 `imports/`）写。

## Item 5c — zip 恢复不删备份里没有的旧文件（未改恢复，验证通过）

**未改恢复逻辑**（仍是“宁留孤儿，不误删”）。验证结论：孤儿清理
覆盖恢复后的孤儿，理由：

- 恢复只写 `imports/` / `slices/` 下的文件（其它条目直接拒绝整个包），
  数据库整体覆盖；
- `scanOrphanFilesFrom` 扫的正是 `imports/` + `slices/`，对照的是
  恢复后库里 questions 的 `source_path` / `page_image_path` /
  `slice_path` 与 collect_tasks 的 `source_path` 四列——恢复后不再被
  任何行引用的文件都会被列出；
- 设置页每次打开数据组都会重新扫描一次，有孤儿就提示清理。

测试（1 项，走真实导出→恢复→扫描）：备份时只有 q1 引用
`slices/q1.png`；恢复前多了 q2（引用 `slices/q2.png`）与旧孤儿文件；
恢复后 q2 的行没了、两个文件都在盘上；孤儿扫描列出
`slices/q2.png` 与 `imports/task-old/x.jpg`，不含在用的
`slices/q1.png`；清理只删孤儿（删 2 个），q1 的图还在。

## Item 5d — 崩溃残留的 staging 清理

改动（`lib/data/database.dart`）：`migrateDataFiles` 开头（早期返回
之前）调新增 `_deleteStaleMigrationStaging(dst)`：只删目标旁边、
名字严格匹配 `.<目标名>.staging-<纯数字时间戳>` 的**目录**（时间戳是
`millisecondsSinceEpoch`，只含数字；`.<目标名>.staging-backup`、
别的目标名、缺前导点、普通文件一概不动）；失败静默跳过，不阻塞本次迁移。

测试（2 项）：迁移成功且残留 staging 被清、四个不匹配项都在；
同位置迁移（`sameLocation` 早期返回）也先清残留 staging。

## 验证

- `flutter analyze`：0 问题。
- `flutter test test/p0_hardening_test.dart test/b2_leftover_data_test.dart`：
  **29 项通过**（P0 文件 12 项 + 本批新文件 17 项）。
- 邻近回归：`flutter test test/p3_backup_migration_test.dart test/p2_json_fields_test.dart`：
  **39 项通过**（`migrateDataFiles` 的调用方与 `*From` 方法的使用方）。
- 未跑全量测试（任务要求：全量由协调方最后带备份跑）；未跑
  `flutter build`；未推送。

## 改动清单

| 文件 | 改动 |
|---|---|
| `lib/data/database.dart` | Item 4：`insertExamInto` / `insertKnowledgePointInto`（UPDATE-first）、`allTagsFrom` / `allExamsFrom` / `allKnowledgePointsFrom`（`ORDER BY rowid`）；Item 5a：`migrateDataFiles` 的 `keepBackups` / `outBackups` / `outMoved`、新 `rollbackMigrationFiles`、`migrateToDirectory` 的标记失败回滚与成功后删 `.old`、新 `testMarkerDirectory`；Item 5d：新 `_deleteStaleMigrationStaging`（迁移开头调用）；Item 5b 的边界说明写进 `migrateDataFiles` 的文档注释 |
| `test/b2_leftover_data_test.dart`（新增，17 项） | Item 1 原子性×4、Item 4 顺序×4、Item 5a×5（静态×2 + 端到端×3）、Item 5b 现状锁定×1、Item 5c×1、Item 5d×2 |
| `docs/ui-replication/B2-LEFTOVER-DATA.md`（本文件） | 报告 |
