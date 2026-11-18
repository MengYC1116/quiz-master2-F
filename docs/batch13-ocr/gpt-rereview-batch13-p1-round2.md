# GPT 窄复审材料（第二轮）：十三批 P1-1 剩余 1 项——接受候选原子性

> 给主代理的说明（不发给 GPT）：用当前对话 https://chatgpt.com/c/6afd45b7-3774-83eb-8cd7-cec9fc0f3e54 发下面正文。**必须先打开思考模式再发**；如果该对话提示上下文已满，另开新对话，第一句先说“请先读一下之前的对话和你的记忆。”再发正文。回复里要确认思考模式是开着的。

---

## 正文

背景：这是十三批 M8 窄复审的第二轮。你上一轮的结论是有条件通过：P1-2、P1-3 PASS，P1-1 只剩 1 项——人工接受候选 `acceptCandidateStem` 的 hash 校验与最终写入原子性未证明（竞态：T1 读 slice_path=H1 并确认 hash 后，T2 重框把 slice_path 改成 H2 提交，T1 再把 H1 的候选写进去；另要求 hash 不符时标 stale 的操作也要有条件约束，不能误标另一个新候选）。你还留了一个代码核验点：worker 持有任务后的全部状态修改是否都传了非空 lease token。下面只写这一处改动与核验证据，请只评 P0/P1（会丢数据、会错写数据、会卡死主流程、安全漏洞、明显错误逻辑）。品味问题请记为已知局限，不要定为 P0/P1。通过就说 PASS，不过就指出具体问题和修法。

### 一、接受候选已改成原子操作（按你给的修法）

`acceptCandidateStem`（lib/modules/ocr/stem_correction.dart）已重写，不再是“重读→算 hash→返回待保存对象→调用方再 repo.save”三步分开。现为单个 Drift 事务（照抄你已认可的 `OcrWorker.applyClaimedResult` 的既成模式），事务内依次做：

1. 重读题目行（`d.select(d.questions)..where(id)`，事务内读到的行就是写入时比较的行）；
2. 确认候选仍 pending（无候选 → `no_candidate`；已接受/已忽略/stale → `not_pending`；题目不存在 → `question_deleted`；均在事务内抛，无写入、直接回滚）；
3. 确认当前 slice_path 与候选来源一致：以事务内读到的行的 `slice_path` 为准，在事务内算文件 hash（切片是不可变版本文件，同一路径内容不会变；`inputHash` 为 null 的十三批前遗留包跳过 hash 核对）；文件不存在 → `slice_missing`；
4. 条件更新写题干、切分状态、候选状态和版本号，检查更新行数。

接受成功写入的 SQL（`customUpdate`）：

```sql
UPDATE questions SET ocr_stem = ?, ocr_split_status = ?, ocr_raw = ?, content_version = content_version + 1 WHERE id = ? AND ocr_raw = ?
```

变量顺序：`split.stemText`、`split.status.label`、状态为 accepted 的 raw JSON、`question.id`、事务内读到的 pending raw 原串。`WHERE` 里 `ocr_raw = ?` 把写操作绑定到事务内验过的那个 pending 包上——写入前候选被并发改动时行数为 0；行数 ≠1 时抛 `StateError` 回滚整笔，调用方按 `save_failed` 处理。`content_version + 1` 在 SQL 里算，不读旧值加；不要求 content_version 仍等于领取时版本（人工改过题干但切片没变时仍可接受，你 §2.3 的要求，未改）；题干一律从 raw 包里经 `splitStem` 取，不用调用方传的预览字符串。成功时直接在事务内落库并返回已保存的题——整理页与详情页的 `acceptOcrCandidateWithReason()` 已删掉分开的 `repo.save`，返回契约不变（成功 null / 拒绝原因原样返回 / 其余失败 `save_failed` / 无当前题 `no_question`）。

hash 不符标 stale 的 SQL（同一事务内，`customUpdate`）：

```sql
UPDATE questions SET ocr_raw = ?, content_version = content_version + 1 WHERE id = ? AND ocr_raw = ?
```

变量顺序：状态为 stale 的 raw JSON、`question.id`、事务内读到的 pending raw 原串。行数 1 才算标上——迟到的新候选已写回时行数为 0，不写、不误标；标完事务正常提交，提交后再抛 `CandidateRejection('hash_mismatch', …)`。拒绝原因/文案契约不变。

两处有意保留的行为，请复核：

1. 接受 SQL 不写 `ocr_manual_edited` 列，返回对象保持事务内读到的原值（旧代码是强制 `true`）。证据：pending 候选在全库只有一处写出——`OcrWorker.applyClaimedResult` 的人工改过档（lib/services/ocr_queue.dart 约 626 行，`result.rawData.withCandidate(…)`，该档只在 `row.ocrManualEdited == 1` 时走）；且没有任何路径把该标志清回 0（全库只有 `applyManualStemEdit` 置 true、upsert 时原值写回、备份恢复原值写回）。因此旧代码强制 true 与新行为在所有可达状态上等价，现有测试仍断言接受后为 `true`。
2. 写库成功后发一次 `DataChangeBus` 事件 `{badges, questions}`（写后发，事务提交后才发）——与旧流程里 `repo.save` → `upsertQuestion` 发的事件同口径；否则去掉 `repo.save` 会让依赖该事件的页面少一次刷新。

未动的 `candidateStemForQuestion`（预览 helper）：它仍走先读后写的 `repo.save` 标 stale。原因是它是整理页/详情页编辑中 OCR 到达时的 widget 守门路径，调用方用 fake repo；改成真实库事务会把守门 widget 测试卷进来，超出本批范围。接受时原子重验兜底，误标窗口只影响一次预览展示，函数注释已注明此决策。

### 二、Lease token 代码核验点：已逐条确认，无生产路径漏传

逐条读过 `lib/services/ocr_queue.dart` 与 `lib/data/db_ocr_jobs.dart`，worker 持有任务后的全部状态修改在生产代码里都传了 `job.leaseToken`：

| 持有后状态修改路径 | 传 token？ |
|---|---|
| 没 key：`retryOcrJob`（约 307 行） | 是 |
| 请求前：`markOcrJobAttempt`（约 354 行），返回 null 时旧 worker 直接返回、不发请求 | 是 |
| `_handleFailure` apiKeyMissing：`retryOcrJob`（约 383 行） | 是 |
| `_handleFailure` 可重试：`retryOcrJob`（约 393 行） | 是 |
| `_handleFailure` 终态：`_failWithoutEmit` → `failOcrJob`（约 402、414 行） | 是 |
| `_fail` → `_failWithoutEmit` → `failOcrJob`（题目已删/切片已换/文件缺失等，约 414 行） | 是 |
| `applyClaimedResult` 内 `_failJobInTxn` → `failOcrJobIntoImpl`（约 444 行） | 是 |
| `applyClaimedResult` 内 `completeOcrJobIntoImpl`（约 677 行），返回 null 时抛 `_LeaseLostException` 回滚整笔 | 是 |
| `processOne` 的未预期异常 → `_handleFailure`（约 383–402 行） | 是（经上表两路） |

不带 token 的只有真正的管理操作与兼容旧调用：`reclaimExpiredLeases`（worker 启动时回收过期租约、清 token，约 158 行）、`clearNoKeyOcrWait`（worker 启动 / 保存 key 后，只清 `api_key_missing` 等待行的 `available_at`，不改持有状态，约 164、193 行）、`enqueueOcrJob`（领任务前，无租约存在）、`claimNextOcrJob`（领任务本身，生成 token）。`complete` / `fail` / `retry` / `markAttempt` 在 `lib/` 下只有 `ocr_queue.dart` 调用；`_updateJobRow` 的 `leaseToken == null` 分支（id 唯一条件，不校验持有者）只剩测试里的直接调用。生产代码无漏传，无需补。

### 三、测试证据

新增接受原子性组 3 项（test/b13_p1_1_candidate_test.dart，真实库 + 真实切片文件）：

- a. stale 标记不误标新候选：先启动接受（事务内读到旧候选、在算 hash 的等待窗口里写回一个 input_hash 与当前切片一致的新候选），终态 raw 必须是新候选的 pending JSON，绝不能是旧候选的 stale JSON；接受本身以 `hash_mismatch` 被拒，题干不动。
- b. 并发接受 + 重框循环 6 轮：每轮 `Future.wait` 同时跑接受与重框（重框写版本化新切片文件并更新题目行 `slice_path`），终态只允许两种合法结果之一——接受先提交（题干为旧候选、状态 accepted，随后重框换切片）或重框先提交（接受被拒 `hash_mismatch`、候选 stale、题干不动）；且题干/切分状态/raw/版本号四者一致、无半截写。
- c. 版本不一致人工改过仍可接受，且返回的对象即已落库（不再需要调用方另行保存）。

租约失效新增 worker 级测试 2 项（同文件租约组）：租约丢了后，可重试失败的 `retry` 不写库、终态失败的 `fail` 不写库（任务保持回收后的 pending，`attemptCount` 为 1，错误码未被旧 worker 写上）。原 DB 级错 token 测试（complete/fail/retry/markAttempt 错 token 返回 null）与回收测试保留。

Notifier 接受测试迁移到真实测试库（test/b13_stem_correction_test.dart、test/b13_p1_2_reenqueue_m4_test.dart）：FakeRepo 的内存列表与真实库双插题，断言改读真实库；未给生产代码加测试缝。旧接受组（成功、hash 不符、重复接受、无候选等）全部保留通过。

验证汇总：相关测试 `b13_p1_1_candidate_test` 31/31、`b13_stem_correction_test` 41/41、`b13_p1_2_reenqueue_m4_test` 14/14；邻近回归 `b13_ocr_queue` + `detail/organize_notifier` 67/67、widget 89/89；**全量回归 1695/1695（基线 1690 + 新增 5），`flutter analyze` 0 问题，Linux Release 构建通过，演示库 md5 不变**（跑前已备份）。除本处改动外，候选数据结构、队列架构、切片方案、备份格式均未改。
