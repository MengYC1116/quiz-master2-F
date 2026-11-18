# P1-1 报告：OCR 候选来源绑定 + 应用原子性（GPT §2.3/§2.4）

- 批次：十三批 P1-1（GPT 关口审 M3 候选机制问题）
- 时间：2026-11-18
- 范围：只做 P1-1。未碰 P1-2（重框入队 await 化）/P1-3（LaTeX 备份泄漏）/M4 的活；未推送代码；未给 Meng 发邮件/消息；未改 `docs/decision-log.md`（D-112 条目草稿见 §6，请统筹追加）。
- 演示库：跑测试前已备份到 `~/workspace/demo-db-backup/quiz-master2.db.b13-p1-1-start`；跑后 `~/.local/share/quiz-master2/quiz-master2.db` md5 仍为 `8f7f9c64405dc6e484ac2bf8e5e1a807`，不变。
- 结论：GPT §2.3、§2.4 的 5 项修法全部落地；§3.1、§3.3 两项建议均已修（不是只核查）；`enqueueOcrForQuestion` 契约已冻结。`flutter analyze` 全仓 0 问题。

## 1. 改动文件清单

### 生产代码（16 改）

| 文件 | 改动 |
|---|---|
| `lib/services/glm_ocr_client.dart` | 候选包加来源身份（§2）；`_defaultSender` 超时强关（§5）；`endpointOverride` 仅单测用 |
| `lib/services/ocr_queue.dart` | 原子应用 `applyClaimedResult`（§4）；租约 token 全程校验（§5）；`notifyApiKeySaved` + 启动清等 key 等待（§6）；入队契约注释 |
| `lib/modules/ocr/stem_correction.dart` | `acceptCandidateStem` 重验证 + `CandidateRejection`（§3）；`dismissOcrCandidateFlag` 写 ignored；`candidateStemForQuestion` hash 感知；新增 `markCandidateStale`；`enqueueOcrForQuestion` 契约冻结（§7） |
| `lib/models/models.dart` | `OcrJob` 加 `leaseToken` 字段 + `copyWith` |
| `lib/data/drift/tables/ocr_jobs.dart` | Drift 表加 `leaseToken` 列；`quiz_database.g.dart` 已重新生成（`dart run build_runner build`，只动 ocr_jobs 相关生成代码） |
| `lib/data/db_schema.dart` | 全新 v4 建表 DDL：`ocr_jobs` 加 `lease_token TEXT` |
| `lib/data/drift/quiz_database.dart` | v3→v4 迁移 DDL：同一列同一字面量（两者逐字一致，M2 的教训） |
| `lib/data/db_ocr_jobs.dart` | claim 生成 token；complete/fail/retry/markAttempt 校验 token；回收/终态清 token；新增 `clearNoKeyOcrWait` |
| `lib/data/db_backup.dart` | `knownColumns['ocr_jobs']` 加 `lease_token`（15 列）；恢复插库加 `leaseToken`（缺键走 NULL） |
| `lib/services/import_service.dart` | 新增 `nextSliceRelative`（版本化切片路径） |
| `lib/state/detail_notifier.dart` | 重框/自愈写版本化新文件 + 标 stale；`acceptOcrCandidate()` 无参化；`rerecognizeCurrent` 接入队抛错；重框入队挂 onError 兜底 |
| `lib/state/organize_notifier.dart` | `acceptOcrCandidate()` 无参化；`rerecognizeCurrent` 接入队抛错 |
| `lib/modules/detail/question_detail_page.dart` | 接受适配：预览字符串不再传给 Notifier |
| `lib/modules/organize/organize_page.dart` | 同上 |
| `lib/modules/settings/settings_page.dart` | 保存 key 后调 `notifyApiKeySaved()`（代替换 `kick()`） |
| `lib/data/drift/quiz_database.g.dart` | 重新生成（未跟踪文件，见上） |

### 测试（1 新 + 4 改）

| 文件 | 内容 |
|---|---|
| `test/b13_p1_1_candidate_test.dart` | **新建**，26 项（§8） |
| `test/b13_stem_correction_test.dart` | 接受 API 改异步重验证；重框断言改版本化路径；接受期望改 split 后题干 |
| `test/b13_migration_test.dart` | 新增：全新 v4 与迁移后 v4 都有 `lease_token` 列 |
| `test/b1_stage1_schema_test.dart` | 期望 DDL 的 ocr_jobs 行加 `lease_token TEXT` |
| `test/detail_page_test.dart` | 新增重框不可变测试；SR3-10 自愈测试改新行为；SR2-3 测试改等自愈落袋 |

## 2. 候选包：来源身份与状态机

`GlmOcrRawData`（`lib/services/glm_ocr_client.dart`，ocr_raw JSON 包）新增：

| 字段 | 含义 |
|---|---|
| `input_hash` | 产出这份 raw 的任务所用的切片 SHA-256（候选的来源身份） |
| `claimed_content_version` | 任务领取时题目的 `content_version`（候选的来源身份） |
| `candidate_status` | 候选状态，见下 |
| `created_at` | 候选包创建时间 |

- **created_at 的说明**：本包没有独立的创建时间字段，`created_at` 与既有 `completed_at_ms` 是**同一值**（worker 写完这份 raw 的毫秒时间戳）。写包时两个键同值；读包时优先 `created_at`、缺失时回退 `completed_at_ms`（十三批前旧包只有后者）。代码里 `createdAtMs` 是 `completedAtMs` 的 getter。
- **状态机**（`OcrCandidateStatus`，JSON 存枚举名）：`none`（无候选：刚自动应用完、或 LaTeX 不平衡原图回退）→ `pending`（等待用户处理，唯一可接受的状态）→ `accepted` / `ignored` / `stale`（终态）。`has_unseen_candidate` 保留为派生字段（= status 是否 pending），仅为兼容而读写，新逻辑一律以 `candidate_status` 为准。
- **旧包兼容**：只有 `has_unseen_candidate`、没有 `candidate_status` 的旧包按旧标志换算（true → pending，false → none）；未知状态值时回退旧标志，不抛。
- **stale 的触发点**（任一处发现 hash 不一致即标 stale，`content_version` 不一致不标——用户只改了题干、切片没变时候选仍可保留比较）：
  - worker 应用结果时 hash 不一致（§4）；
  - 用户接受候选时 hash 不一致（§3，先标 stale 再拒绝）；
  - `candidateStemForQuestion` 预览时 hash 不一致（best-effort 标 stale）；
  - 重框/自愈成功后（新切片 hash 已算出，`markCandidateStale` 纯函数）。

## 3. 接受候选时重新验证

`acceptCandidateStem(QuestionRepository repo, Question question)`（`lib/modules/ocr/stem_correction.dart`，替代已删的纯函数 `applyCandidateStem(Question, String)`）：

1. 经 repo 重读库里最新行——题目不存在抛 `question_deleted`；
2. 候选仍 pending——无候选（raw 缺失或状态 none）抛 `no_candidate`；已接受/已忽略/stale 抛 `not_pending`；
3. 候选 `input_hash` 与当前切片 hash 一致——不一致时先把库里候选标 stale 再抛 `hash_mismatch`；切片文件不存在抛 `slice_missing`。

- **不要求 `content_version` 仍等于领取时版本**（GPT §2.3）：用户人工改过题干但切片没变时，正是需要比较并主动接受的情形；测试锁定“版本 5→7 仍可接受”。
- **接受的题干一律从 ocr_raw 包里经 `splitStem` 取**（与 `pendingCandidateStem` 预览同款推导），不用调用方传的预览字符串——页面/Notifier 的 `acceptOcrCandidate()` 已无参化，`OcrStemSection` 的 `onAcceptCandidate(String)` 回调签名不变（页面适配层忽略该参数）。行为变化：旧实现把调用方传的候选字符串原文写入 ocr_stem，新实现写入 split 后的题干（选项不进题干）；既有测试期望已随之更新。
- `inputHash` 为 null 的是十三批前的遗留包，无基线可比，跳过 hash 核对（也不要求切片文件存在）——十三批未推送，新包恒有 hash。
- `dismissOcrCandidateFlag`：只把 pending 候选写 ignored（`contentVersion +1`）；无候选/已接受/已忽略/stale 时原样返回（重复忽略是空操作，`identical` 锁定）。

## 4. 自动应用必须原子

`OcrWorker.applyClaimedResult(job, claimedVersion, result)`（`lib/services/ocr_queue.dart`，`@visibleForTesting` 单测入口；`_applyResult` 是其薄壳，写了库才发事件）：

- **同一个 Drift 事务**内做：重读题目行 → 切片核验 → 版本比较 → 条件写入 → 任务完成。检查与写入之间没有 await 敞口。
- **三档条件更新**（`customUpdate`，检查实际更新行数）：
  - 安全档：`UPDATE questions SET ocr_raw=?, ocr_stem=?, ocr_split_status=?, content_version=? WHERE id=? AND content_version=? AND ocr_manual_edited=0`，行数 ≠1 → `content_changed` 丢弃，绝不静默成功；
  - 人工改过档：只写 ocr_raw（候选 pending，带 input_hash 与 claimed_content_version）+ `content_version = content_version + 1`，条件 `ocr_manual_edited = 1`；版本不一致不丢弃（候选保留比较）；
  - LaTeX 不平衡档：只写 ocr_raw（状态 none）+ 版本 +1，stem 不动。
  - `content_version + 1` 在 SQL 里算，不读旧值加。
- **版本比较规则**（GPT §2.3 的表）：未人工改过且版本与领取时不一致 → 丢弃；人工改过时版本不一致走候选档。
- **hash 核验以题目行 `slice_path` 为准**（本次修法中发现的关键缺口）：不可变切片下，旧任务的 `crop_path` 指向的旧文件字节永不变，只比文件 hash 会漏掉“已重框”——重框后题目行 `slice_path` 指到新版本文件，路径变了就是换了，迟到结果直接丢弃（`hash_mismatch`），旧候选标 stale。新切片的候选（input_hash 等于当前 hash）不会被误标。请求前的预检（`_processClaimed`）同样先比 `slice_path`。
- **租约丢失回滚**：事务内 `complete` 校验 token 返回 null 时抛 `_LeaseLostException`，整笔写回回滚，返回 false（不发事件）；丢弃路径的 `fail` 校验失败时不写库、不回滚已提交的 stale 标记（标记本身与任务无关，正确）。

## 5. 租约 token

- `ocr_jobs` 加 `lease_token TEXT`（可空；pending/failed/completed 行恒为 null）。十三批未推送，v4 只存在于本地树与测试里——**直接改未发布的 v4 DDL，未建 v5 迁移**：全新 v4 建表 DDL（`db_schema.dart`）与 v3→v4 迁移 DDL（`quiz_database.dart` 的 `_upgrade3To4`）同一字面量逐字一致；Drift 表定义加列后重新生成 `quiz_database.g.dart`；B1 schema 锁定测试与 M2 迁移测试同步更新。
- claim 时生成唯一 token（`newEntityId('lease')`，毫秒时间戳 + 8 位安全随机），与 started_at/lease_until 同一事务写下；两次领任务 token 不同（测试锁定）。
- `complete` / `fail` / `retry` / `markAttempt` 都接受可选 `leaseToken` 参数：非空时在 WHERE 里加 `lease_token = ?`，更新行数为 0 时返回 null、不做任何写操作（任务已被回收重领）；旧调用方不传 token 时行为不变。
- 回收过期租约与终态（完成/失败/重试回 pending）都清 token；备份互通：`knownColumns['ocr_jobs']` 加 `lease_token`（15 列），恢复插库缺键走 NULL（旧备份的任务行本来就没有租约；恢复后 running 行由启动时租约回收处理）。

## 6. 切片用不可变版本文件

- 新增 `ImportService.nextSliceRelative(questionId)`：`slices/<id>-v<毫秒时间戳>-<8 位随机>.png`，每次重框/自愈都不同名。
- 详情页重框（`DetailNotifier.applyReworkBoxes`）与自愈（`_healSliceIfNeeded`）写新切片一律用版本化路径，绝不原地覆盖；旧文件留盘（孤儿扫描清理，本次不删）。**不变量：一个切片路径的字节在入队后永不变化。**
- 自愈分两种情形：库里路径的文件不存在（重框事务已提交、rename 前被杀）→ 按当前框重裁，直接写到库里记的路径（该路径尚无文件，是首写不是覆盖）；文件存在但尺寸不符（旧崩溃窗口残留）→ 写版本化新路径，库里 `slice_path` 指过去，旧候选标 stale。
- 首次写盘（确认分框 `sliceRelative`）仍用 `slices/<id>.png`——该路径尚无文件，是首写不是覆盖。

## 7. GPT 建议核查（§3.1、§3.3）：两项都修了

- **§3.1 超时 abort**：`_defaultSender` 改为实例方法，整体请求包一层 `timeout(requestTimeout)`，超时回调里 `client.close(force: true)` 再抛 `TimeoutException`（`Future.timeout` 本身不等于底层请求取消；超时后整个 client 丢弃，不复用）。连接超时改走实例的 `connectTimeout`（旧代码硬编码 15 秒）。验证：本地原始 TCP 服务端（只收字节、永不响应）实测——客户端 300ms 超时抛 `timeout`，服务端在 4 秒内观测到连接断开；abort 后新客户端第二次请求成功。另加仅单测用的 `endpointOverride`（生产恒为 null）以便指到本地测试服务器。注入的 sender 无法强制取消，仍只包一层 timeout（注释已写明）。
- **§3.3 保存 key 后 kick**：旧行为确实会挡——`kick()` 只唤醒循环，`available_at` +10 分钟仍在未来，任务领不到。已修：新增 `AppDatabase.clearNoKeyOcrWait`（只清 `last_error_code = api_key_missing` 的 pending 行的 `available_at`，不改状态、不清错误码）；`OcrWorker.notifyApiKeySaved()` 先清等待再 `kick()`，设置页保存 key 后调它；worker `start()` 时也清一次（key 已补上时立即领；key 仍缺时下一轮仍按 `noKeyDelay` 等，不空转）。

## 8. `enqueueOcrForQuestion` 契约（冻结，P1-2 接手）

`Future<OcrJob?> enqueueOcrForQuestion(AppDatabase db, Question question)`（`lib/modules/ocr/stem_correction.dart`）：

- 正常完成、值为 `OcrJob`：任务已持久化入队；
- 正常完成、值为 null：无切片（slicePath 为空或文件不存在），没建任务——**不是失败**，调用方不因此报错；
- 以异常完成：读盘/写库失败（入队失败），调用方必须处理（P1-2：await 并向用户展示“题目已更新，OCR 未入队”+重试入口），不得静默吞掉。`unawaited` 调用时须挂 onError 兜底。
- 切片变了才建新行；入队后 kick 已启动的 worker。
- 已改的调用点：整理页/详情页 `rerecognizeCurrent` 接住抛错返回 false；详情页重框的 fire-and-forget 调用挂了 onError 兜底（P1-2 再改为 await）。批量 `enqueueForQuestions` 仍逐道吞错、只返回成功列表（见 §9 遗留）。

## 9. 测试结果

测试环境：`TMPDIR=$HOME/workspace/flutter-test-tmp`，`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`，`flutter test --concurrency=1`。

### 本模块（6 文件，130/130 全过）

| 文件 | 通过 |
|---|---|
| `test/b13_p1_1_candidate_test.dart`（新，26 项） | 26/26 |
| `test/b13_ocr_client_test.dart`（19 项） | 19/19 |
| `test/b13_ocr_queue_test.dart`（18 项） | 18/18 |
| `test/b13_stem_correction_test.dart`（41 项） | 41/41 |
| `test/b13_migration_test.dart`（17+1 项） | 18/18 |
| `test/b13_ocr_settings_test.dart`（8 项） | 8/8 |
| **共计** | **130/130** |

新文件 26 项覆盖：候选包往返/旧包换算/状态流转（3）；接受重验证——版本不一致仍可接受、hash 不一致拒绝+标 stale+重复接受拒绝、题目已删、重复接受、已忽略/无候选、切片不存在、预览 hash 不一致返回 null 并标 stale（7）；忽略候选重复空操作、`markCandidateStale` 规则（2）；自动应用原子性——识别期间人工改过/版本变了/题目被删/重框换新文件/直测条件更新/租约丢了整笔回滚（6）；租约 token——claim 唯一、token 不匹配四处不写库、回收/终态清 token（3）；入队契约——无切片 null、同片去重、写库失败抛错（2）；`nextSliceRelative` 唯一性（1）；§3.3 保存 key 后立即领取（1）；§3.1 本地慢服务器超时 abort 且服务端观测到断开（1）。

### 邻近回归（262/262 全过）

| 文件 | 通过 |
|---|---|
| `test/detail_page_test.dart`（42 项，含新增重框不可变 1 项） | 42/42 |
| `test/organize_page_test.dart` | 与下列合计 220/220 |
| `test/b13_stem_splitter_test.dart` | 同上 |
| `test/m1_formula_renderer_test.dart` | 同上 |
| `test/collect_page_test.dart` | 同上 |
| `test/app_shell_test.dart` | 同上 |
| `test/b1_stage1_schema_test.dart` | 同上 |

`flutter analyze`（全仓）：**No issues found**。

### 修测试时发现并已修的连带问题

- B1 schema 锁定测试含旧 ocr_jobs DDL 字面量（已同步加 `lease_token TEXT`）。
- `detail_page_test` 的 SR2-3 测试依赖自愈原地改写旧文件：已按新行为改等自愈落袋（等 `slice_path` 指到 `slices/q1-v…` 且新文件 492 宽），基线改为自愈后的新切片；旧文件仍逐字节比对。

## 10. D-112 条目草稿（请统筹追加到 docs/decision-log.md）

> **D-112（十三批 P1-1：OCR 候选来源绑定 + 应用原子性，GPT §2.3/§2.4）**：ocr_raw 候选包加来源身份（`input_hash`、`claimed_content_version`、`candidate_status` 五值 none/pending/accepted/ignored/stale、`created_at` 与 `completed_at_ms` 同值）；接受候选时重验证（题目存在、input_hash 与当前切片一致、候选仍 pending，任一不符拒绝并给明确原因，hash 不一致标 stale；不要求 content_version 仍等于领取时版本；题干从 raw 包经 splitStem 取）；自动应用在同一 Drift 事务内做状态核验 + 版本比较 + 条件更新（安全档 `WHERE id=? AND content_version=? AND ocr_manual_edited=0`，行数 ≠1 不算成功；人工改过只写 raw 作候选；hash 不一致标 stale；租约丢了整笔回滚）；ocr_jobs 加 `lease_token` 列（claim 生成唯一 token，complete/fail/retry/markAttempt 校验持有者，不一致不写库；直接改未发布 v4 的两份 DDL，未建 v5）；切片用不可变版本文件（重框/自愈写 `slices/<id>-v<时间戳>-<随机>.png`，旧文件留盘；核验以题目行 slice_path 为准）；请求超时后 HttpClient 强制关闭（§3.1）；保存 key 后等 key 的任务立即变为可领取（§3.3）；`enqueueOcrForQuestion` 契约冻结（成功 OcrJob / 无切片 null / 失败抛错，P1-2 按此接手调用点）。

## 11. 遗留问题

1. **接受失败原因未透传到 UI**：`CandidateRejection.reason`（question_deleted / no_candidate / not_pending / hash_mismatch / slice_missing）目前只到 Notifier 返回 false，页面仍显示通用“保存失败，请重试”。P1-2/M5 可接：按 reason 给明确文案。
2. **批量入队仍逐道吞错**：`OcrWorker.enqueueForQuestions`（确认分框批量入队）仍 catch 每道失败、只返回成功列表；P1-2 接手调用点时应一并处理（至少让调用方知道有题没排上）。
3. **遗留包祖父条款**：无 `input_hash` 的十三批前旧包跳过 hash 核对（十三批未推送，实际不存在此类数据；如以后出现带候选的旧备份，需注意）。
4. **租约 token 不是鉴权凭据**：`newEntityId('lease')` 只是唯一随机值，用于持有者比对，不作安全鉴权；不写日志、不外露。
5. **全量测试是 M7 的事**：本次只跑了本模块 130 项 + 邻近回归 262 项，未跑全量。
6. **旧候选标 stale 的版本 +1**：标 stale 时 `content_version +1`（raw 变了，按 M3 规则）；正在编辑该题的表单不受影响（M5 守门只读候选状态，不刷新表单值）。
