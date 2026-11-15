# Batch 7 P2 — 文档组修复报告（SR3-7 / SR3-16 / SR3-26～SR3-33 / SR3-35）

- 执行员：第七批文档组工人
- 日期：2026-11-15
- 分支：`ui-replication`；工作树 `~/workspace/quiz-master2-UI`
- 范围：只修第三次自审（SELF-REVIEW-3.md / SELF-REVIEW-3-DOCS.md）点名的 11 项文档/注释问题；不改产品代码逻辑，不提交、不推送。
- 方法：逐项 grep/实跑核实数字后再改；改完 `flutter analyze` 全仓复核 + grep 逐项复核。未跑全量测试（按任务要求）。

## 逐项修法与核对

### 1. SR3-7（P2）— B6 报告三处数字与代码事实不符

- (a) `b5_p2_data_test` 36→**56**（不是 36→55）：
  - 核实：当前文件 `grep -c "test("` = 56；`git show 6448c45` 计 36。逐项求和亦为 20（C-data 新增 19 + GAPS 的 SR2-27 补 1）。
  - 改动：`B6-SUMMARY.md` C-data 小节改为“36→56（C-data 新增 19 项 + GAPS 的 SR2-27 补 1 项）”；`B6-P2-DATA.md:35` 改为“36 项 → 56 项（新增 19 项，见上表；另 SR2-59 改名 1 处；GAPS 的 SR2-27 补 1 项。成文时为 55 项，SR2-27 在后才加）”。
  - 注：`B6-P2-DATA.md:52` 的“（55 项）”未动——它是成文时（02:09 UTC，SR2-27 在 02:20 UTC 后才加）对“待总协调补跑的文件规模”的如实记录，不是“36→55”的汇总 claim；与 SELF-REVIEW-3-DOCS.md DOCS-1 的“成文时是对的”一致。
- (b) `_failAndClean` 调用点 **13 处**（不是 9 处）：
  - 核实：`grep -n "_failAndClean(" lib/services/import_service.dart` 共 14 命中，减去 :581 的定义本身 = **13 处调用点**（:348、:443、:463、:496、:498、:502、:505、:508、:522、:540、:542、:546、:568；enqueue 内 3 处 + `_importPdf` 内 10 处）。Batch 5 是 10 处。
  - 改动：`B6-SUMMARY.md:21`“9 个调用点”→“13 个调用点”；`B6-P1-IMPORT.md:53`“一处修、九处调用点受益”→“一处修、十三处调用点受益”；另顺带修正 `lib/services/import_service.dart:578-580` 的同款错误注释（“9 处调用点只有尾部 1 处有保护，在这里包一处，九处受益”→“13 处……十三处受益”）——纯注释改动，无逻辑改动。实质无问题：守卫在函数内部，13 处调用点全部受益。
- (c) `b5_p2_services_test` 的“15/15”已过时，现 **25 项**：
  - 核实：`grep -cE "^\s*(test|testWidgets)\("` = 25（18 个 `test(` + 7 个 `testWidgets(`）；**实跑** `flutter test --concurrency=1 test/b5_p2_services_test.dart`：**25/25 通过**（`All tests passed!`，约 19 秒，2026-11-15 本次修复时跑）。
  - 改动：`B6-SUMMARY.md:25`、`B6-P1-IMPORT.md:14`、`:153` 三处均改为 25/25，并注明“A-import 成文时文件为 15 项，D-services 随后追加 SR2-24/SR2-78 等分组至 25 项”。

### 2. SR3-16（P2）— “拦住”论证补适用边界（Meng 已定口径 (a)，文档级）

- 改动：`B6-P1-QUEUE.md`“与规定修法的出入”小节、选 (b) 的理由后补一段引用块：
  > **适用边界（SR3-16，第三次自审补）**：上文的“拦住”只保页内动作——切题、开队列、进详情、改排序、保存草稿；不保离页。用户点左导航或返回离开整理页时，没有任何保存尝试与未保存提示，持续保存失败下表单改动仍会静默丢失。产品级离页守卫（`PopScope` + 离页前保存/确认）另立项，本批不做。
- 核对：6 处调用点逐一核对无误的结论（SR3-16 证据）未动；产品级离页守卫未做（另立项，待 Meng 定）。

### 3. SR3-26（P2）— 整理页测试基数 30→29

- 核实：`git grep` 计数 `6448c45` 时 `test/organize_page_test.dart` 为 29 项；当前文件 `grep -cE "^\s*testWidgets?\("` = 38；29+9=38。
- 改动：`B6-SUMMARY.md:47`“38/38（30 + 9 新增，含 1 个对照）”→“38/38（原 29 + 新增 9 = 38，含 1 个对照）”；`B6-P1-QUEUE.md:8`“（原 30 + 新增 9，其中 1 个为对照用例”→“（原 29 + 新增 9 = 38，其中 1 个为对照用例”。

### 4. SR3-27（P2）— `docs/代码地图.md:9-11` 头注 Batch 6 状态过期

- 改动：与 SR3-35 一并更新（见第 11 项）：头注新增“Batch 6（第二次自审 78 项修复）已完成、已推送（2026-11-15 ~11:41，远端 head `38cbc4b`）；最终验证：analyze 0 问题、全量测试 852/852、Linux Release 构建成功，结论见 `B6-SUMMARY.md`”；“第六批修复进行中，其改动未提交”改为“第七批修复进行中，其改动未提交、未推送，在 Meng 明确批准之前不要 push”；“仓库里仍有 Batch 1/2/3/4/5 未提交的改动”改为“仓库里仍有未提交的改动（……本地 head `bca8586`……；Batch 6 已推，远端 head `38cbc4b`）”。

### 5. SR3-28（P2）— B6-SUMMARY“遗留”补收 7 处阶段报告级遗留

- 改动：`B6-SUMMARY.md` 末尾“遗留（未修 / 需另定）”小节追加“另见第三次自审补收的 7 处阶段报告级遗留（SR3-28……）”编号子列，逐条与源报告原文对过：
  1. A-import：EXIF 镜像方向分支的“失败写库”未单独立用例（源 `B6-P1-IMPORT.md` 遗留第 2 条）。
  2. A-detail：B5 的旧 P2-3 测试仍只覆盖“无旧切片”场景，有旧切片的覆盖在 `detail_page_test.dart`，两处未合并（源 `B6-P1-DETAIL.md` 遗留第 3 条）。
  3. A-split：已拆过的页（`alreadySplit`）上后画的独立内框，确认时仍随 `continue` 静默丢弃（源 `B6-P1-SPLIT.md` 遗留第 1 条）。
  4. A-queue：`_jumpToQuestion` 失败时弹出层已先关闭，用户需重开队列再跳（源 `B6-P1-QUEUE.md` 遗留第 2 条）。
  5. D-services：SR2-38 的 `minSize: true` 分支里 `(minSize && …)` 判断恒为真（`!minSize` 已提前返回），留作原样（源 `B6-P2-SERVICES.md` 遗留第 2 条）。
  6. D-services：SR2-31 的金角步进只在第 13 科钉死字面值，第 14、15…科未逐个断言（源同文件遗留第 3 条；产品行为侧面见 SR3-21，Meng 已定 1° 细粒度扫描，另批修）。
  7. GAPS：SR2-73 的 500ms 等待是“等第二次检测到达 `_ensureLoaded`”的经验余量，解码极慢的环境下计数可能为 2（源 `B6-P2-GAPS.md` SR2-73 补跑重点）。
- 注：A-dropdown 的 `_filterExamId` / 复习页 `_subjectFilter` 未覆盖已在总结 A-dropdown 小节内写明，未重复。

### 6. SR3-29（P2）— B6-SUMMARY 遗留 SR2-16 一条已过时

- 改动：原句“SR2-15 并发测试依赖 sqflite 事务串行化；SR2-16 对既有备份 fixture 的影响面待全量确认。”拆为两条：
  - “SR2-15：并发用例依赖串行化语义，换库后端时需复核（已知脆弱性，非待办）。”
  - “SR2-16 对既有备份 fixture 的影响面：第三次全量 852/852 已确认，无回归（原待办已过时，移出待办、仅留此注）。”
- 核对：第三次全量 852/852 通过（含 `p1_schema_backup_test.dart`、`s8b4_backup_migration_test.dart` 等既有备份用例），与总结“最终验证”小节自述一致。

### 7. SR3-30（P2）— 工作树 `test/zz_probe_*.dart` 残留核实

- 核实：`ls test/zz_probe_*` → 无此文件；`git status` 无 zz_probe 相关条目。**当前工作树无残留，无需删除。**协调员 2026-11-15 04:35 UTC 核实清理完毕的结论仍然成立（4 个 TEMP 探针文件均已删，不在已推提交 `38cbc4b` 内）。
- 另：本次修复未新建任何探针文件。

### 8. SR3-31（P2）— 任务清单 `/tmp/b6-files.txt` 补 README.md

- 改动：首行插入 `2026-11-15 01:40 UTC README.md`（mtime 01:40:42.613，早于原首行 `docs/decision-log.md` 的 01:40:42.670，时序正确）。清单现为 63 条。
- 核对：`git diff 6448c45..38cbc4b --name-only` 共 63 个文件；清单去时间戳后排序与 diff 逐项比对**完全一致**（`diff` 无输出）。

### 9. SR3-32（P2）— `B6-P1-DOCS.md`“全局核对”措辞

- 改动：“`已于 Batch 5（SR-P2-13）删除` 3 处（D-04、README、代码地图 :118）”→“3 处（D-04、README、代码地图 :118；README 一处因换行断开，字面 grep 命中 2 处）”。
- 核对：`README.md:61-64` 该句确被换行断开（“…`demoQuestions()` 已于 Batch 5 / （SR-P2-13）删除…”），字面 grep 只命中 `docs/decision-log.md:36` 与 `docs/代码地图.md:119` 两处；三处改动本身均已就位，错的是验证方法的宣称。

### 10. SR3-33（P2）— 行号漂移

- 改动：`B6-SUMMARY.md` A-detail 备注里的 `db_collect.dart:325` → 实测 `:338`（`replaceQuestionBoxesAndSliceIntoImpl` 在 `:338`，grep 核实）；同句追加“（SR3-33：B6 各报告其余漂移的行号不逐条改旧报告，后续引用以 grep/符号为准。）”
- 未动：其余漂移引用（`B6-P1-DOCS.md` 代码地图 :477/:118、`B6-P1-DETAIL.md` P2-3 测试组约 :891-960、`B6-SUMMARY.md` GAPS `home_page_test.dart:110` 等）均按 SR3-33 处方不逐条改旧报告。

### 11. SR3-35（P2）— 推送后状态过期（CODEBUDDY / 四方分工 / 代码地图）

- 核实：远端 head 确为 `38cbc4b`（`git ls-remote origin ui-replication` 与 `git log origin/ui-replication` 均确认；`38cbc4b Batch 6: fix second self-review 78 items…`，2026-11-15 ~11:41 经 Meng 批准推送）。
- 改动：
  - `docs/CODEBUDDY.md`“当前状态”：远端 head `6448c45`→`38cbc4b`；“Batch 1–5 已推送……第六批修复已完成、在工作树里，未提交、未推送”→“Batch 1–6 已推送（Batch 6：2026-11-15 ~11:41，远端 head `38cbc4b`）；第三次自审已做完（见 `SELF-REVIEW-3.md`，只审第六批改动，P0 0、P1 2、P2 33），第七批修复进行中、改动在工作树里，未提交、未推送”；“不要 push”改为“不要 push（针对第七批）”。
  - `docs/四方分工.md`“眼前第一步”：同款更新——第六批“已完成并已推送（2026-11-15 ~11:41，远端 head 38cbc4b）”，第三次自审已做完，第七批修复进行中，推送等 Meng 另外批准；末尾更新注同步。
  - 另：复核时发现同文件头注 :8 还有一处同类过期表述（“第六批修复进行中……最新数以第五批汇总 B5-SUMMARY.md 为准”，SR3-35 未点名），顺带同步为“第六批修复已完成并已推送（2026-11-15 ~11:41，远端 head 38cbc4b），全量测试 852/852，最新数以第六批汇总 B6-SUMMARY.md 为准”；头注其余基线内容（2026-11-14 基线、远端 afb68e3、628/628）是当时的基线记录，未动。
  - `docs/代码地图.md:9-11`：见第 4 项（与 SR3-27 一并更新）。
- 未动：`B6-SUMMARY.md` 自身“不提交、不推送（推送须 Meng 另外批准）”是本批执行原则的历史记录，按任务要求未改。

## 验证

- `flutter analyze`：全仓复跑 **0 问题**（`No issues found!`，17.1s，2026-11-15 本次修复后跑）。
- grep 逐项复核：改后 `B6-SUMMARY.md` / `B6-P1-IMPORT.md` / `B6-P2-DATA.md` 内无残留“36→55”“9 个调用点”“九处调用点”“15/15”“30 + 9”；`B6-P1-QUEUE.md` / `B6-P1-DOCS.md` 内无残留“原 30”与旧“3 处”措辞；三处状态文档内无残留“第六批修复已完成、在工作树里，未提交、未推送”“未推送，推送等 Meng 另外批准”“第六批修复进行中”；`import_service.dart` 内无残留“9 处调用点”。
- 单文件实跑：`test/b5_p2_services_test.dart` 25/25 通过（见第 1(c) 项）。
- 未跑全量测试（按任务要求，留给总协调）。
- 未提交、未推送。

## 遗留

- SR3-16 的产品级离页守卫（`PopScope` + 离页前保存/确认）另立项，本批只做了文档级适用边界；待 Meng 定。
- SR3-28 补收的 7 条阶段报告级遗留本身未修（只补进总结遗留），其中第 6 条的产品行为侧面（SR3-21 金角 15 科后兜底）Meng 已定 1° 细粒度扫描，另批修。
- SR3-33 其余漂移行号有意未逐条改旧报告，后续引用以 grep/符号为准。
- 本次只动了任务书列明的 11 项；工作树内另有其他执行员未提交的 Batch 7 改动（lib/ 与 test/），未碰。
