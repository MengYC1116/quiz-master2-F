# GPT 窄复审材料：quiz-master2 十三批 P1 修复（P1-1 / P1-2 / P1-3 + M4）

> 给主代理的说明（不发给 GPT）：用当前对话 https://chatgpt.com/c/6afd45b7-3774-83eb-8cd7-cec9fc0f3e54 发下面正文。**必须先打开思考模式再发**；如果该对话提示上下文已满，另开新对话，第一句先说“请先读一下之前的对话和你的记忆。”再发正文。回复里要确认思考模式是开着的。

---

## 正文

背景：这是十三批 M8 关口审的窄复审。你上次的结论是暂不 PASS，3 个 P1（P1-1 候选机制、P1-2 重框入队、P1-3 备份泄漏证据未闭合），其余 M1/M2/M3 队列/M4/M5 守门/M6/Key/Windows secure storage 全部 PASS。下面只写三处改动与测试证据，请只评 P0/P1（会丢数据、会错写数据、会卡死主流程、安全漏洞、明显错误逻辑）。品味问题请记为已知局限，不要定为 P0/P1。请逐项给结论，通过就说 PASS，不过就指出具体问题和修法。

### 一、P1-1 候选机制（按你 §2.3、§2.4 修）

候选包（ocr_raw JSON）加来源身份：`input_hash`（产出这份 raw 的任务所用切片 SHA-256）、`claimed_content_version`（任务领取时题目的 content_version）、`candidate_status`（五值 none/pending/accepted/ignored/stale）、`created_at`（与既有 `completed_at_ms` 同值，读包时优先 created_at、缺失回退 completed_at_ms）。`has_unseen_candidate` 保留为派生字段（= status 是否 pending），仅为兼容而读写，新逻辑一律以 `candidate_status` 为准。旧包（只有 has_unseen_candidate）按旧标志换算（true → pending，false → none）。

接受候选时重新验证（`acceptCandidateStem`，替代旧的纯函数）：经 repo 重读库里最新行——题目不存在抛 `question_deleted`；候选仍 pending——无候选抛 `no_candidate`，已接受/已忽略/stale 抛 `not_pending`；候选 `input_hash` 与当前切片 hash 一致——不一致时先把库里候选标 stale 再抛 `hash_mismatch`；切片文件不存在抛 `slice_missing`。不要求 content_version 仍等于领取时版本（你 §2.3 的要求：用户人工改过题干但切片没变时，正是需要比较并主动接受的情形；测试锁定版本 5→7 仍可接受）。接受的题干一律从 ocr_raw 包里经 `splitStem` 取（与预览同款推导），不用调用方传的预览字符串。`inputHash` 为 null 的十三批前遗留包跳过 hash 核对（十三批未推送，新包恒有 hash）。

stale 的触发点（hash 不一致即标 stale，content_version 不一致不标）：worker 应用结果时 hash 不一致；用户接受候选时 hash 不一致（先标 stale 再拒绝）；`candidateStemForQuestion` 预览时 hash 不一致（best-effort 标 stale）；重框/自愈成功后（`markCandidateStale` 纯函数）。

自动应用必须原子（`OcrWorker.applyClaimedResult`，`@visibleForTesting` 单测入口）：同一个 Drift 事务内做重读题目行 → 切片核验 → 版本比较 → 条件写入 → 任务完成，检查与写入之间没有 await 敞口。三档条件更新（`customUpdate`，检查实际更新行数）：安全档 `UPDATE questions SET ocr_raw=?, ocr_stem=?, ocr_split_status=?, content_version=? WHERE id=? AND content_version=? AND ocr_manual_edited=0`，行数 ≠1 → `content_changed` 丢弃；人工改过档只写 ocr_raw（候选 pending，带 input_hash 与 claimed_content_version）+ 版本 +1，条件 `ocr_manual_edited = 1`，版本不一致不丢弃（候选保留比较）；LaTeX 不平衡档只写 ocr_raw（状态 none）+ 版本 +1，stem 不动。`content_version + 1` 在 SQL 里算，不读旧值加。hash 核验以题目行 `slice_path` 为准（关键缺口：不可变切片下旧任务的 `crop_path` 指向的旧文件字节永不变，只比文件 hash 会漏掉“已重框”——重框后题目行 `slice_path` 指到新版本文件，路径变了就是换了，迟到结果直接丢弃 `hash_mismatch`，旧候选标 stale；请求前的预检同样先比 `slice_path`）。租约丢失回滚：事务内 `complete` 校验 token 返回 null 时抛异常，整笔写回回滚，返回 false（不发事件）。

租约 token：ocr_jobs 加 `lease_token TEXT` 列（可空；pending/failed/completed 行恒为 null）。十三批未推送，v4 只存在于本地树与测试里——直接改未发布的 v4 DDL，未建 v5 迁移：全新 v4 建表 DDL 与 v3→v4 迁移 DDL 同一字面量逐字一致；Drift 表定义加列后重新生成。claim 时生成唯一 token（毫秒时间戳 + 8 位安全随机），与 started_at/lease_until 同一事务写下；两次领任务 token 不同（测试锁定）。`complete` / `fail` / `retry` / `markAttempt` 都接受可选 `leaseToken` 参数：非空时在 WHERE 里加 `lease_token = ?`，更新行数为 0 时返回 null、不做任何写操作。回收过期租约与终态都清 token。备份互通：`knownColumns['ocr_jobs']` 加 `lease_token`（15 列），恢复插库缺键走 NULL。

切片用不可变版本文件：新增 `ImportService.nextSliceRelative(questionId)`，`slices/<id>-v<毫秒时间戳>-<8 位随机>.png`，每次重框/自愈都不同名。详情页重框与自愈写新切片一律用版本化路径，绝不原地覆盖；旧文件留盘（孤儿扫描清理，本次不删）。不变量：一个切片路径的字节在入队后永不变化。自愈分两种情形：库里路径的文件不存在（重框事务已提交、rename 前被杀）→ 按当前框重裁，直接写到库里记的路径（该路径尚无文件，是首写不是覆盖）；文件存在但尺寸不符（旧崩溃窗口残留）→ 写版本化新路径，库里 `slice_path` 指过去，旧候选标 stale。首次写盘（确认分框）仍用 `slices/<id>.png`（该路径尚无文件，是首写不是覆盖）。

你 §3.1、§3.3 的两项建议也修了：请求超时后强制关闭 HttpClient（`_defaultSender` 改为实例方法，整体请求包一层 `timeout(requestTimeout)`，超时回调里 `client.close(force: true)` 再抛 `TimeoutException`；本地原始 TCP 服务端实测——客户端 300ms 超时抛 `timeout`，服务端在 4 秒内观测到连接断开；abort 后新客户端第二次请求成功；注入的 sender 无法强制取消，仍只包一层 timeout，注释已写明）。保存 key 后 kick：旧行为确实会挡（`kick()` 只唤醒循环，`available_at` +10 分钟仍在未来）。已修：新增 `AppDatabase.clearNoKeyOcrWait`（只清 `last_error_code = api_key_missing` 的 pending 行的 `available_at`，不改状态、不清错误码）；`OcrWorker.notifyApiKeySaved()` 先清等待再 `kick()`，设置页保存 key 后调它；worker `start()` 时也清一次。

`enqueueOcrForQuestion` 契约已冻结：`Future<OcrJob?>`——正常完成值为 OcrJob 表示任务已持久化入队；值为 null 表示无切片（不是失败）；以异常完成表示读盘/写库失败，调用方必须处理，不得静默吞掉；`unawaited` 调用时须挂 onError 兜底；切片变了才建新行；入队后 kick 已启动的 worker。

### 二、P1-2 重框入队 + M4 歧义 UI（按你 §5.2、§4.2 修）

重框入队改 await：`DetailNotifier.applyReworkBoxes` 在框与切片落库（事务 + rename 成功）之后才入队，`await _enqueueForRework(...)`（默认 = 冻结契约的 `enqueueOcrForQuestion`）确认任务已持久化；只有 `worker.kick()` 是 fire-and-forget（它在 `enqueueOcrForQuestion` 内部调，生产代码不动）。入队抛错只记标志，不改返回值：`ReworkOutcome` 仍是 `success`（框选结果已落库，不能因 OCR 失败谎称重框失败），页面不把“框选成功”等同于“OCR 已排队”。失败标志两处存：`DetailState.ocrEnqueueFailed` + Notifier 私有 `_ocrEnqueueFailedQuestionId`；`load()` 重建 state 时按题 id 显式算 `keepEnqueueFailed` 再写进 `copyWith`——同题重读保留，切题/题不存在清除。详情页显“题目已更新，OCR 未入队”横幅 + “重新入队”按钮（走同一入队路径重试，成功后横幅消失；无切片返回 null 不算失败）。`retryOcrEnqueue()` 成功（含 null）返回 true 并清标志、调 `_refreshOcrStatus`；抛错返回 false，标志保留，可再点重试。

批量入队诚实提示（P1-1 遗留）：`OcrWorker.enqueueForQuestions` 仍逐道吞错、只返回成功列表（未改）。调用点 `CollectNotifier.confirmSplit` 尾部按 questionId 比对返回的任务行，未入队数非阻塞附在成功提示后（“其中 X 道题 OCR 未入队，可在详情页重新识别。”）；`worker == null` 或 `enqueueForQuestions` 抛错时按全部未入队报，宁可多报不可静默丢题；`outcome.kind` 仍是 `done`，整理主流程绝不被 OCR 卡住。计数是纯函数 `ocrEnqueueMissedCount(questions, jobs)`。

测试缝：`DetailNotifier.enqueueOcrForTest`（`@visibleForTesting` 静态注入，生产恒 null，走冻结契约）。真实 Drift 在 widget 测试 fake async 下连跑会挂住（诊断：首个测试的 `runAsync` 恰好把开库链抢救出来，后续测试的入队不再完成；`tester.runAsync` 轮询加到 20 秒仍失败，是真挂住不是慢；不值得继续追单行——真实库 await 本来就不属于 fake async widget 测试），详情页重框 widget 测试走缝；真实入队路径由真实库 plain 测试覆盖。生产绝不为过测试改回 `unawaited`。

M4 歧义为独立内容状态：`OcrStemSection._ambiguousBanner()`，在 `question.ocrSplitStatus == OcrSplitStatus.ambiguous`（“存在歧义”）时显示，与编辑态无关，放在 header 行之后：标题“识别结果待确认”，正文逐字用你的文案：“识别内容包含无法确定的选项边界，请检查题干内容。”不混进队列七态——`deriveOcrStemStatus` 未改；“切分：存在歧义”小标签与状态 chip（如“识别完成”）原样保留，横幅只叠加。位置在共用的 `OcrStemSection`，整理页与详情页自动都有。

接受失败原因透传（P1-1 遗留）：`DetailNotifier.acceptOcrCandidateWithReason()` / `OrganizeNotifier` 同款：成功返回 `null`；`CandidateRejection.reason` 原样返回；其余失败返回 `'save_failed'`；无当前题返回 `'no_question'`。旧 `acceptOcrCandidate()` 改为 `== null` 委托，行为不变。`candidateRejectionMessage(reason)`：`question_deleted` / `no_question` → “题目已被删除，候选无法接受”；`no_candidate` → “没有待处理的识别结果”；`not_pending` → “这份识别结果已经处理过，不能重复接受”；`hash_mismatch` → “识别结果来自旧切片（已重新框选），已标记为过期，不能接受”；`slice_missing` → “切片文件不存在，无法核对候选来源”；`save_failed` / 其他 → “保存失败，请重试”。详情页与整理页都已接上，不再一律“保存失败，请重试”。

### 三、P1-3 备份泄漏：实测事实 + Meng 的决定（请按决定评审，不要重开方案讨论）

按你 §6.3 的 sentinel 方法实测（测试 `test/b13_backup_sentinel_test.dart`，3/3 通过）：标记 `\frac{SENTINEL_A}{SENTINEL_B}` 各一份放入临时测试题的 `ocr_stem` 与 `ocr_raw`（`md_results`）后，走产品真实导出代码路径：JSON 备份全文命中 `SENTINEL_A` 与 `\frac`（文件内为 JSON 转义的 `\\frac` 形态），`questions` 行的 `ocr_raw`、`ocr_stem` 列均命中；zip 备份仅含 `backup.json` 一个条目（不含 `.db` 文件），解压后 `backup.json` 命中 `SENTINEL_A` 与 `\frac`；本地 `.db` 文件关库后字节搜索命中 `SENTINEL_A` 与 `\frac`（单反斜杠原样），`-wal` / `-shm` 关库后不存在。备份格式：JSON 导出为 `_meta` + 15 张表 `SELECT *` 后 `jsonEncode`，`ocr_raw` / `ocr_stem` 无过滤；zip 为 `backup.json` + 引用的 `imports/` / `slices/` 文件，deflate 压缩、无加密。

Meng 2026-11-18 16:46 已定：留着，界面看不到就行。备份文件与本地 SQLite 文件里明文存 LaTeX 可以接受，P1-3 按接受关闭；sentinel 实测报告与测试文件作为证据保留，不删。边界已记入决策日志 D-112：“不外露”只管界面（UI / 复制 / 报错 / 日志），不含备份与本地库文件。请按这个已定的边界评审 P1-3 是否闭合，不要要求改备份格式或加加密。

### 四、测试证据

- 全量测试 **1690/1690**（基线 1644 + 新增 46：P1-1 新 26、P1-2 新 14、P1-3 新 3、迁移测试 +1、详情页 +2），`flutter analyze` 0 问题，Linux Release 构建通过，演示库 md5 不变（标准 v1，9 道题）。
- P1-1 模块测试 130/130（新文件 26 项：候选包往返/旧包换算/状态流转；接受重验证 7 项；忽略/标 stale 2 项；自动应用原子性 6 项；租约 token 3 项；入队契约 2 项；`nextSliceRelative` 唯一性 1 项；保存 key 后立即领取 1 项；本地慢服务器超时 abort 1 项）+ 邻近回归 262/262。
- P1-2 模块测试：新文件 14/14（重框入队失败/重试真实库 3 项、接受原因透传 4 项、M4 横幅 4 项、批量提示 3 项）+ `detail_page_test` 43/43 + 邻近回归 373/373。
- P1-3 实测：新文件 3/3（JSON 备份、zip 备份、本地 .db 文件各 1 项）。
- 回归插曲（已解决）：P1 修复后首轮全量 1686 通过 + 4 失败，全部是测试侧问题、生产代码零改动——(1) SR3-10 自愈测试写死了旧原地覆盖断言，改断言新行为（新版本化文件 492×280、旧文件字节不变）；(2) SR-P2-3 重框事务失败测试：详情页打开时自愈（缺失文件分支）已首写出库里记的现行切片，事务失败只删临时文件、绝不删现行切片（否则重演 SR2-3 丢图 bug），测试预摆尺寸相符旧切片；(3)(4) SR-P2-22 两项是共享 `_testTmp` 串扰（SR-P2-3 残留的自愈切片让 `slices/` 为空断言失败，生产清理单跑验证正常），SR-P2-3 自带 `tearDown` 清理。构建环境：`libgtk-3-dev` 重装（3.24.41），`libzstd1` 显式降级到发行版 `1.5.5+dfsg2-2build1.1`（`+hatch1` 版与 `libzstd-dev` 冲突）。
- 泄漏检查：无硬编码 key；getApiKey() 只在客户端拼 Authorization 头与队列判有无 key 处调用，设置页不调用；复制只走 PNG 字节；ocr_raw 只内部解析；VL-1.6 仅注释提到报告文件名、无实现；SimpleTex 0 命中。

### 五、已知局限（不用定为 P0/P1，除非你认为它们实际是）

1. `b5_p2_collect_test.dart` 的临时目录是 `setUpAll` 全文件共享的，任何用例在 `slices/` 留文件都会让 SR-P2-22 的全目录断言失败；本次只修了 SR-P2-3 这一处，后续用例若再写 `slices/` 须自带 `tearDown` 清理。
2. `libzstd1` 的 `+hatch1` 版与 `libzstd-dev` 冲突是复发隐患；如下次 apt 又把它升回去，构建会再次失败，同款命令可解。
3. B13 部分旧测试把切片写进真实数据目录（未设 `testDataDirectory`），是既有行为，本次未动。
4. 切片自愈与重框并发竞跑：打开详情页时 `_healSliceIfNeeded`（后台）与用户重框可能同时读写同一道题的切片字段；实测影响只限测试断言，生产行为不受影响（横幅/重试/入队均按题 id 与现切片走）。
5. 无 `input_hash` 的十三批前遗留候选包跳过 hash 核对（十三批未推送，实际不存在此类数据；如以后出现带候选的旧备份，需注意）。
6. 租约 token 只是唯一随机值，用于持有者比对，不作安全鉴权；不写日志、不外露。

### 六、请重点看的点

1. 候选包的来源身份与五态机有没有漏掉的竞态：迟到结果、重框后旧候选、重复接受/忽略、人工编辑后接受，是否都按 §2.3 的表处理？
2. 自动应用的事务内条件写入有没有敞口：检查与写入之间、租约丢失时、人工改过档的版本处理，是否真正原子？
3. 租约 token 的校验有没有漏掉的路径：claim/complete/fail/retry/markAttempt、启动回收、备份恢复后的 running 行，是否都一致？
4. 不可变切片有没有漏掉的写路径：确认分框首写、重框、自愈、导出/复制等，是否还有原地覆盖旧文件的路径？事务失败时新版本化文件与临时文件的清理是否完整？
5. 重框 await 入队有没有漏掉的失败路径：入队抛错、load() 后标志保留、重试成功/失败、无切片 null，页面是否始终不把“框选成功”等同于“OCR 已排队”？
6. M4 歧义横幅是否真正独立于队列七态：存在歧义且无任务、存在歧义且识别完成时，横幅与状态 chip 是否各自正确？
7. P1-3 按 Meng 已定的边界（“不外露”只管界面，不含备份与本地库文件）是否闭合？

请逐条回答，给出明确结论：PASS，或 P0/P1 + 具体修法。
