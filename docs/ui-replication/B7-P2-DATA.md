# Batch 7 · 数据层（B7-P2-DATA）

- 日期：2026-11-15。执行员：第七批修复数据层组。
- 范围：只修第三次自审数据层 SR3-3、SR3-4、SR3-5、SR3-6、SR3-9（P2，5 项）。SR3-8 只观察、不改代码；SR3-7 由文档组修；SR2-19 只核对口径、不改代码。
- 未提交、未推送。

## SR3-3 — 框查询 orderBy 补齐 + 测试注释修正

- 修法：`lib/data/db_collect.dart` 的 `boxesForQuestionFromImpl` 与 `boxesForTaskPageFromImpl` 各补 `orderBy: 'page ASC, id ASC'`（与 `boxesForTask` 同口径），各加一行 SR3-3 注释。
- 测试注释：`test/b5_p2_data_test.dart:722` 旧注释“题行本身也倒序插入，钉住题 id 列表的顺序”改为实话——最终框顺序只由框查询的 `ORDER BY` 决定，题 id 列表的 `orderBy: 'id ASC'` 经本测试不可观测（只影响中间 IN 列表）；倒序插入只是为了排除对插入/rowid 序的依赖。
- 新增用例 1 项（同文件 SR2-27 组内）：`boxesForQuestionFrom / boxesForTaskPageFrom 也按 page ASC, id ASC`——同题多框乱序插入后按 page/id 返回；某任务某页草稿框同页内按 id 排、他页不混入。注意：同题多框用 layer=2 框——layer=1 框有“每题一框”的部分唯一索引（`db_schema.dart:214`），同题挂四个 1 层框会违反约束；第一版用例因此报 `UNIQUE constraint failed: question_boxes.question_id`，已按此修正。
- 验证：`test/b5_p2_data_test.dart` 62/62 通过（含本项新增 1 项）。

## SR3-4 — `upsertCauseRecord` 窄化显性化（选修法 a）

- 选 (a) 不选 (b) 的理由：(b) 恢复整行 UPDATE-first 会重新引入 SR2-14 刚堵住的危害——旧快照覆盖自查刚改掉的 `status` / `solvedCount` / `recheckDate`；`recordSelfCheckIntoImpl` 的事务内重算只保护它自己那一次提交，挡不住之后一次旧快照全量 upsert 的覆盖。窄化是正确语义，错的是名字。
- 修法：
  - `lib/data/db_questions.dart`：`upsertCauseRecord` 改名 `updateCauseRemedy`，注释重写——只写 `remedy_history` 列；状态/计数/复查日/上次自查的唯一写路径是 `recordSelfCheckIntoImpl`；行不存在时才整行 INSERT（新记录无可覆盖的库内值）。同时修正旧注释里“`saveCauseRecord` 在 lib/test 里无调用方”的错误说法（`test/b5_p1_1_subject_counts_test.dart:242` 播种时在用）。
  - `lib/data/repository.dart`：`saveCauseRecord` 保留为仓库层公开入口（任务要求的钉住点），转发到 `updateCauseRemedy`，并加注释写明契约——行已存在时 `status` / `solvedCount` / `recheckDate` / `lastCheck` 的改动按设计丢弃、不写入，改状态走 `recordSelfCheck`；行不存在时整行 INSERT。`saveRemedy` 的调用点改为 `updateCauseRemedy`。
  - 旧名 `upsertCauseRecord` 在 lib/test 已无引用（仅新注释里提及旧名作说明）。
- 用例：
  - 既有用例改名并改调用点：`旧快照 updateCauseRemedy 只改 remedy_history，不覆盖自查改掉的状态/计数/复查日`。
  - 新增用例 1 项（SR2-14 组内）：`SR3-4：经 saveCauseRecord 改已存在行的 status 被丢弃（按设计），新行才整行写入`——已存在行：`status: pending / solvedCount: 0` 的改动被丢弃（库内仍为 `solved / 2`、复查日不变），`remedy_history` 写入；不存在行：整行 INSERT，全列按传入值写（`inProgress / 1`）。
- 验证：`test/b5_p2_data_test.dart` 62/62；`test/b5_p1_1_subject_counts_test.dart` 5/5（播种路径仍走 `saveCauseRecord`）。

## SR3-5 — `_dedupKey` 按平台分流

- 修法：`lib/services/import_service.dart:176-190`。可解析分支不变（`resolveSymbolicLinks()` 后小写折叠，Windows/macOS 的真实同文件仍去重）；解析失败的回退分支不再折叠小写——`File(path).absolute.path` 与原样 `path`，让不存在的大写拼写不再与真实文件撞键。注释同步改写，写明代价：Linux 下 `[真实, 不存在的大写]` 会建两个任务（一个 needBox、一个 failed），是诚实行为；Windows 上两种拼写打开同一文件，仍只建一个任务。
- 用例（`test/import_service_p1_fixes_test.dart`，SR-P1-17 组内）：
  - 既有用例改期望：`同文件大小写不同写法（SR2-72/SR3-5）`——`[真实, 大写]` 顺序现为 2 个任务（`{needBox, failed}`），旧“只建一个任务”的断言已按新口径改写，注释说明 Linux/Windows 差异。
  - 新增用例 1 项：`不存在的大写拼写在前（SR3-5）：真实文件仍导入，不被遮蔽`——`[大写不存在, 真实]` 顺序：2 个任务，`photo.jpg` 进 needBox、`PHOTO.JPG` 为 failed；旧行为下这里只剩 1 个失败任务。
- 验证：`test/import_service_p1_fixes_test.dart` 19/19 通过。

## SR3-6 — `onProgress` 入口包永不抛错的转发

- 修法（选入口包一层）：`lib/services/import_service.dart` 的 `enqueue` 入口把 `onProgress` 包成 `safeOnProgress`（回调抛错只吞掉），五处调用点全部改走它——复制循环内、图片 90%、图片 100%、传给 `_importPdf` 的那一份（覆盖其内部渲染回调与 PDF 100% 两处）。尾部三处原有的 try/catch 保留作双保险。未动 `_importPdf` 签名（它只被 `enqueue` 调用，收到的已是安全转发）。
- 用例（同文件，新增 SR3-6 组，2 项，均为普通 `test`，无异步文件 IO、无 testWidgets）：
  - 图片复制循环内回调抛错：任务仍进 needBox，不判复制失败。
  - PDF 渲染回调内抛错（假引擎渲染 1 页）：任务仍进 needBox、pageCount 1，不判渲染失败。
- 验证：`test/import_service_p1_fixes_test.dart` 19/19；`test/b5_p2_services_test.dart` 25/25（其中有用真实 `onProgress` 回调断言逐次回调的用例，转发层不改变回调语义）。

## SR3-9 — 去重集合提到事务级

- 修法：`lib/data/db_collect.dart` 的 `confirmSplitIntoImpl` 内，`seenBoxIds` 从“题循环内新建 / 页循环内新建（`seenIds`）”改为事务级一个集合——在题循环前声明，题回填与保留分支共用；跨题/跨页重复 id 也跳过，保留第一个。两处插入仍用 `ConflictAlgorithm.replace`（事务内去重后重复已无从到达；保留分支的 replace 另有“保留任务与原任务同 id 先删后插”的用途，不动）。函数头注释与两处行内注释同步更新（SR2-18 同题内 + SR3-9 跨题/跨页）。
- 用例（`test/b5_p2_data_test.dart`，SR-P2-10 组内，新增 2 项）：
  - `跨题重复 id 的框：只保留第一题的，不静默覆盖`——两道题挂同 id 不同坐标的框：第一题留 1 框（x 0.1），第二题 0 框。
  - `保留任务跨页重复 id 的草稿框：只保留第一页的`——保留任务第 1、2 页各挂同 id 草稿框：第 1 页留 1 框（x 0.1），第 2 页 0 框。
- 验证：`test/b5_p2_data_test.dart` 62/62；`test/b5_p1_256_test.dart` 11/11（保留任务分支既有用例）。

## SR2-19 峰值口径核对（不改代码）

- 核对结果：当前行为与 Meng 定的口径一致——维持现状，按峰值算，最终 < 2GB 但峰值 > 2GB 的备份继续拒绝。
- 证据：`lib/data/db_backup.dart:412-414`，`peakBytes = usedBytes + incomingBytes`，`_maxRestoreBytes = 2 * 1024 * 1024 * 1024`（`:318`），`peakBytes > _maxRestoreBytes` 即拒；将被覆盖的旧文件不抵扣（恢复完成前一直占盘），`backup.json` 不进 staging。既有用例 `峰值超 2GB 拒绝：将被覆盖的文件不抵扣峰值（SR2-19/SR2-65）`（现有占用 2GB−100、备份 200 字节、将被覆盖旧文件 500 字节：最终占用 < 2GB、峰值 2GB+100 → 拒绝，旧文件原样不动）随 `b5_p2_data_test.dart` 62/62 通过。
- 未改任何代码。

## SR3-8 观察（不改代码）

- 本次 `test/import_service_p1_fixes_test.dart` 单文件跑 19/19 通过，其中 `恰好 50MB PDF（SR2-71）` 用例本次通过，未复现间歇失败。未改代码，未加 timeout（按任务要求只观察）。

## 验证汇总

- `flutter analyze`：4 个 info（`avoid_print`），全部在 `test/zz_probe_sr3_22_test.dart`（未入库的 TEMP 探针文件，服务层组 SR3-22 的探针，不属本组范围，未动）。本组改动的 6 个文件 0 问题。
- 相关测试文件串行跑（`--concurrency=1`，`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`）：
  - `test/b5_p2_data_test.dart`：62/62（原 56→62：本组新增 4 项；另有 2 项为树内其他组同期新增——本组未动其内容）
  - `test/import_service_p1_fixes_test.dart`：19/19（原 16→19：本组新增 3 项，另 1 项既有用例按 SR3-5 新口径改期望）
  - `test/b5_p1_1_subject_counts_test.dart`：5/5
  - `test/b5_p2_services_test.dart`：25/25
  - `test/b5_p1_256_test.dart`：11/11
  - `test/p2_main_chain_test.dart`：13/13
  - `test/p1_schema_backup_test.dart`：21/21
  - `test/b3_p01_path_safety_test.dart`：26/26
- 未跑全量（按任务要求，全量由协调员最后统一跑；演示库有删库风险）。
- 未提交、未推送。

## 遗留

1. `flutter analyze` 的 4 个 info 在 `test/zz_probe_sr3_22_test.dart`（未入库探针，服务层组所有）：请协调员通知属主跑完删除，或由门禁前统一清理；本组未动该文件。
2. SR3-8（50MB PDF 间歇失败）本次未复现，根因仍未证实；门禁重跑时留意该用例，如再现需保留完整失败输出再定性。
3. SR3-4 的 `repository.saveCauseRecord` 名字仍是“全量保存”的口吻，实际契约已是仅写补救历史（注释 + 用例已钉死“丢弃是按设计”）。如将来要彻底消除误读，可再改名（如 `saveCauseRemedy`），但会动测试播种调用点，本批未做。
4. SR3-5 的 Linux 取舍仍在：同目录仅大小写不同的两个真实文件仍会被折叠去重（注释已写明“病态构造”，产品跑在 Windows 上）。
