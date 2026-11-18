# M3 报告：OCR 客户端 + 后台队列

- 批次：十三批，模块 M3
- 时间：2026-11-18
- 范围：只做 M3（OCR 客户端 + 后台队列）。未碰 M5 的 UI、M6 的设置页（只留了 OcrKeyStore 契约给 M6 接）；未给 Meng 发邮件/消息；未推送代码；未做任何 git 操作（本地 HEAD bca8586 是 stale 的，工作区此前已有其他模块的大量未提交改动——本报告只列 M3 自己的文件；共享文件 database.dart / app.dart / collect_notifier.dart / pubspec.* 里其他模块的改动不是 M3 的）。
- 演示库：跑测试前已备份到 `~/workspace/demo-db-backup/quiz-master2.db.b13-m3-start`；跑后 `~/.local/share/quiz-master2/quiz-master2.db` md5 仍为 `8f7f9c64405dc6e484ac2bf8e5e1a807`，不变。

## 1. 改动文件清单

### 生产代码（4 新 + 4 改）

| 文件 | 改动 |
|---|---|
| `lib/services/ocr_key_store.dart` | **新建**：OcrKeyStore（flutter_secure_storage 封装），见 §2 |
| `lib/services/glm_ocr_client.dart` | **新建**：GLM-OCR Dart 客户端（layout_parsing）+ 白边 + LaTeX 括号校验 + 错误码表 + ocr_raw 包格式，见 §3 |
| `lib/services/ocr_queue.dart` | **新建**：OcrWorker（单 worker 顺序处理）+ 候选判定 helper（M5 用），见 §4 |
| `lib/data/db_ocr_jobs.dart` | **新建**：ocr_jobs 的 CRUD part 文件（仿 db_recently_viewed.dart 单表 part 模式），见 §5 |
| `lib/data/database.dart` | 改：注册 `part 'db_ocr_jobs.dart'` + 9 个静态转发（enqueue/claim/reclaim/markAttempt/retry/fail/complete/byId/forQuestion） |
| `lib/app.dart` | 改：`_QuizMasterAppState.initState` 里启动 OCR worker（`OcrWorker.ensureStarted()`，见 §4.5） |
| `lib/state/collect_notifier.dart` | 改：`confirmSplit` 成功后入队（`OcrWorker.instanceOrNull?.enqueueForQuestions(questions)`，try/catch 包住，入队失败不影响“已生成 N 道题”） |
| `pubspec.yaml` / `pubspec.lock` | 改：新增 2 个直接依赖——`flutter_secure_storage: ^10.3.4`（解析 10.3.4，Windows 实现 4.1.0）、`image: ^4.13.1`（解析 4.13.1）。其余 lock 变化是工作区此前已有的未提交改动（Drift 迁移等），不是本次引入 |

### 测试（2 新）

| 文件 | 内容 |
|---|---|
| `test/b13_ocr_client_test.dart` | 19 项：KeyStore、白边、括号校验、客户端（假 HTTP 层） |
| `test/b13_ocr_queue_test.dart` | 18 项：入队/领任务/租约/退避/错误分类/三项校验/人工编辑候选/事件/启停 |

## 2. OcrKeyStore 契约（给 M6，类名/方法名/键名冻结）

文件：`lib/services/ocr_key_store.dart`。

```dart
class OcrKeyStore {
  static const String apiKeyStorageKey = 'bigmodel_api_key';
  OcrKeyStore({OcrKeyStorageBackend? backend}); // 默认走 flutter_secure_storage
  Future<String?> getApiKey();   // 无 key 返回 null（不是空串）
  Future<void> setApiKey(String key); // 去首尾空白；空串视为清除（不存空 key）
  Future<bool> hasApiKey();      // 是否已存 key（设置页显示“已设置/未设置”用它，不读出 key）
  Future<void> clearApiKey();    // 清除 key
}
```

- 存储键名固定为 `'bigmodel_api_key'`，勿改。
- key 只存一份；key 值永不打日志（本文件无任何 print/debugPrint；M6 同样不得把返回值写进日志、错误信息或备份）。
- 可测性：构造器可传 `OcrKeyStorageBackend`（生产默认 `FlutterSecureStorageBackend`，即 flutter_secure_storage 的薄封装；单测传内存假后端，不碰平台通道——`flutter test` 里没有平台实现，直接调插件会抛 MissingPluginException）。

### Windows 支持核实（已验证，无需换方案）

- flutter_secure_storage 10.3.4 官方支持 Windows（pub.dev 明示 Android/iOS/macOS/Windows/Linux）；解析到的 Windows 实现是 flutter_secure_storage_windows 4.1.0。
- Windows 后端机制（读了该包的 README 原文）：值经 AES-GCM 加密后存文件（应用支持目录，`key.secure`），加密密钥本身存在 Windows 凭据管理器（Credential Manager）里；向后兼容时也可直接读写凭据管理器。Linux 实现走 libsecret，Android 走 KeyStore。
- **Win11 构建前置条件（请 M6/统筹转告 Meng）**：插件 README 要求 Visual Studio Build Tools 须装 C++ ATL 库，否则 Windows 端编不过。这是构建环境要求，与本文件逻辑无关；Meng 在 Win11 上 `flutter build windows` 前请确认 ATL 已装（`visualstudio.microsoft.com` 下载 Build Tools，勾选 C++ ATL）。

## 3. GLM-OCR 客户端（`lib/services/glm_ocr_client.dart`）

### 调用形态（已验证，见 §8）

- `POST https://open.bigmodel.cn/api/paas/v4/layout_parsing`，body `{"model": "glm-ocr", "file": "<data:image/png;base64,...>"}`，头 `Authorization: Bearer <key>`。不用 chat/completions（对 glm-ocr 返回 HTTP 400）。
- 实现用 `dart:io HttpClient`（无第三方 http 依赖）；key 只从 OcrKeyStore 读。
- 超时：连接 15 秒、单次请求 120 秒（构造器 `connectTimeout` / `requestTimeout` 可配，请求超时取 GPT 建议的 90–120 秒上限）。
- 取 `md_results` 做文本（string 或 string 列表，列表按行拼）；`layout_details` 原样保留在 ocr_raw 包里（它是“列表的列表”：外层是页、内层是块，每块含 `bbox_2d`/`label`/`content`/`index`/`width`/`height`——实测见 §8；本客户端不拆它，原样存，给 M5 的公式原图回退和切分辅助信号用）。

### 白边（`addWhitePadding`，内存里做）

- 发送前每边加原图 30% 的纯白边（`paddingFraction = 0.30`，尖峰结论），原图按原尺寸贴正中央，重编码为 PNG 再发；磁盘切片文件不动（入队时算的 input_hash 是磁盘文件的哈希，与白边无关）。
- 解不出的字节报 `bad_image`；加白边后超 10MB（服务端单文件上限）报 `bad_image`，不发请求。
- 测试锁定：100×50 → 160×80，四角纯白、中央仍是原图。

### LaTeX 括号校验（`hasBalancedLatex` / `unbalancedLatexSegments`）

- 只校验 `$...$` / `$$...$$` 公式段里的 `()` `[]` `{}` 是否配对，以及 `$` 定界符是否成对；转义括号（`\(` `\{` 等）不计；正文里的中文括号 `（）` 不校验。
- 不平衡的公式段不写 ocr_stem（worker 走原图回退，见 §4.3）；校验函数的返回值不得打进日志（可能含 LaTeX）。

### ocr_raw 包格式（`GlmOcrRawData`，M5 按此解析，不要自己拼字段）

```json
{"md_results": "...", "layout_details": [...], "usage": {...},
 "has_unseen_candidate": false, "job_id": "ocr-...", "completed_at_ms": 1731...}
```

- `md_results` / `layout_details` / `usage` 是 GLM 原样返回的内容。
- `has_unseen_candidate`：候选标志（见 §4.4）。
- `job_id` / `completed_at_ms`：产出这份 raw 的任务与完成时间（排障用）。

### 错误码表（`OcrErrorCode`，存 `ocr_jobs.last_error_code`，只增不改）

| 码 | 含义 | 可重试 |
|---|---|---|
| `api_key_missing` | 没填 key：只排队不发请求，不写 failed | 否（等用户填 key） |
| `api_key_invalid` | key 无效或无权限（HTTP 401/403） | 否 |
| `timeout` | 连接超时或单次请求超时 | 是 |
| `http_429` | HTTP 429（优先尊重 Retry-After） | 是 |
| `http_5xx` | HTTP 500–599 | 是 |
| `network` | 网络断开等 Socket 异常 | 是 |
| `bad_image` | 图片损坏 / 解不出 / 超 10MB | 否 |
| `bad_params` | 请求参数错误（HTTP 400 等） | 否 |
| `file_missing` | 切片文件不存在 | 否 |
| `bad_response` | 200 但响应体不符合约定（缺 md_results / 非 JSON） | 否 |
| `question_deleted` | 应用前丢弃：题目已被删（worker 码） | 否 |
| `hash_mismatch` | 应用前丢弃：切片内容变了，与入队哈希不一致（worker 码） | 否 |
| `content_changed` | 应用前丢弃：领取后题目内容版本变了（worker 码） | 否 |
| `internal` | worker 内部未预期异常（如数据库读写失败） | 是（上限 4 次） |

- `OcrException.retryable` 按上表判定；`message` 只写“发生了什么 + 该怎么办”，绝不含 key、LaTeX 原文、图片内容。

## 4. 队列 worker（`lib/services/ocr_queue.dart`）

### 基本形态

- `OcrWorker`：单 worker 顺序处理，并发 1，异步，绝不阻塞 UI 线程（Dart 异步网络请求，不引入 Isolate）。单例（`ensureStarted` / `instanceOrNull` / `resetInstanceForTest`）；单测直接 `OcrWorker(database: ..., recognizer: 假实现)` 构造新实例，不走单例；worker 只依赖 `OcrRecognizer` 接口（`GlmOcrClient` 实现它），识别器可注入假实现。
- 防重入：`start()` 幂等（已启动时直接返回）；循环内任何一步抛错都只歇一轮再继续，不让 worker 静默死掉；`stop()` 等当前一步走完。
- 空闲轮询 5 秒（`ocrPollInterval`）；入队后 `kick()` 可立即唤醒（`CollectNotifier` 入队点未调 kick——入队后最迟 5 秒内开跑，够用；如 M5 要“入队即跑”，再调 `OcrWorker.instanceOrNull?.kick()`）。

### 租约与退避参数（定稿值）

| 参数 | 值 |
|---|---|
| 租约时长 `ocrLeaseDuration` | 5 分钟（领走时写 `started_at` + `lease_until`） |
| 租约回收 | 应用启动时调一次（`start()` 内）；只回收 `running` 且 `lease_until` 已过的任务，回 `pending` 并清 `started_at`/`lease_until`；`lease_until` 为 null 的 running 行不回收（数据异常，留给排障） |
| 最多总请求 `ocrMaxAttempts` | 4 次（首次 + 3 次重试）；`attempt_count` 是实际发起次数，领任务时不加，发请求前才 +1 |
| 退避 | 指数 30 秒 → 60 秒 → 120 秒，上限 5 分钟（`ocrBackoffBase` 30s / `ocrMaxBackoff` 5min） |
| 429 | 优先尊重 Retry-After 秒数，同样封顶 5 分钟（服务端让等更久时，5 分钟后重试大概率仍是 429，再按新的 Retry-After 退避，不丢任务） |
| 没 key | 只排队不发请求：回 `pending`，`available_at` = now + 10 分钟（`ocrNoKeyDelay`），不记 attempt、不写 failed；key 补上后下次领走时自然跑起来 |
| 重试范围 | 只重试 timeout / http_429 / http_5xx / network / internal；key 缺失或无效、图片损坏、参数错误、文件不存在不重试（直接 failed） |

### 入队点

- 确认分框后（`CollectNotifier.confirmSplit` 成功返回前）：每道刚确认的题调 `enqueueForQuestion`——`crop_path` 用题的 `slice_path`（imports//slices/ 相对路径，M2 口径）；`input_hash` 是入队时算的磁盘切片文件 SHA-256（复用 `import_guess.dart` 的 `sha256HexOfFile`；白边在发送时才加，不参与哈希）。
- 去重：同一题 + 同一哈希的未完成任务（pending/running）已存在时返回它，不建重复行（`enqueueOcrJobIntoImpl`）；切片变了（哈希不同）才建新行，旧行由应用前哈希比对丢弃。
- 切片路径为空或文件不存在时不建任务（返回 null），调用方不因此报错。
- 入队失败（读盘/写库）不拦整批，其余题继续排队；整理流程绝不被 OCR 卡住。

### 应用结果前必查三项（任一不符不自动覆盖，进 failed 带丢弃码）

1. 切片 hash 与 `input_hash` 一致（请求前先验一次，省一次 API 调用；应用时再验一次——请求期间切片也可能变）；
2. 题目仍存在；
3. `content_version` 与领取时一致（领取时记下 `claimedVersion`，应用时重读比对）。

### 写回三档（都走 `Question.copyWith(...)` 再 `upsertQuestionInto`，不手写 SQL）

| 情况 | 写回 |
|---|---|
| 安全（LaTeX 平衡、未人工改过） | `ocrRaw`（新包，标志 false）+ `ocrStem`（`splitStem` 结果）+ `ocrSplitStatus`（切分状态中文）+ `contentVersion +1` |
| 人工改过（`ocr_manual_edited=1`） | 只写 `ocrRaw`（候选标志 true，见 §4.4），`ocrStem` 与 `ocrSplitStatus` 原样不动；`contentVersion` 仍 +1（raw 变了） |
| LaTeX 不平衡 | 只写 `ocrRaw`（标志 false），`ocrStem` 不动（M5 按“ocr_raw 有、ocr_stem 空”走原图回退，不是候选）；`contentVersion` +1 |

### content_version 递增规则（M3 定稿，M5 的纠错保存必须遵守）

- 每次 OCR 自动应用 +1：安全应用、候选只写 raw、LaTeX 不平衡只写 raw，三种写回都 +1（只要 ocr_raw 变了，内容版本就变）。
- 每次人工编辑保存 +1：M5 纠错编辑器保存 ocr_stem（或改 ocr_raw 的候选标记）时 `contentVersion +1`——否则 worker 的“领取后内容是否变过”校验失效。
- 其他保存（整理、详情改答案/文件夹等）不碰 content_version——它只跟踪 OCR 内容，不跟踪题目全部字段。

### 候选结果的存放与判定（v4 schema 已够用，不加 v5 迁移）

- 存放：`ocr_raw` 恒写最新原始结果（`GlmOcrRawData` JSON 包）；`ocr_stem` 只在安全时写。人工改过时 worker 把 raw 包里的 `has_unseen_candidate` 置 true 再写 ocr_raw，stem 不动。
- M5 判定“有新的识别结果”：`hasPendingOcrCandidate(question)`——只读 raw 包的 `has_unseen_candidate` 标志，不比较文本、不依赖时间戳。这是 v4 内唯一可靠的判定（只比文本会误报：用户手动改完题干后、没有新 OCR 跑过时，旧 raw 切出的题干与人工题干本来就不同）。
- M5 预览候选题干：`pendingCandidateStem(question)`——对 raw 里的 md_results 再跑 `splitStem`；无候选返回 null。
- M5 清标志：用户保存一次手动编辑、或接受/忽略候选后，用 `clearOcrCandidateFlag(question.ocrRaw)` 把 raw 包里的标志清掉再保存（清标志不改 md_results，原始结果不丢；不清的话下次还会提示同一份候选）。接受候选时：M5 把候选题干写进 `ocr_stem`、`ocr_split_status` 写回切分结果、`ocr_manual_edited` 保持 1（仍是人工确认过的内容）、`contentVersion +1`、raw 标志清掉。
- LaTeX 不平衡的原图回退不是候选：`hasPendingOcrCandidate` 为 false。

### 事件

- OCR 完成/失败/丢弃后发一次 `DataChangeEvent(kinds: {DataChangeKind.questions}, questionId: ...)`（D-94 recentlyViewed 模式：写后发，写失败不发；事件只说“这道题的 OCR 状态变了”，订阅方自己重读库）。
- 注意（给统筹/M5）：整理页当前没有 questions-kind 的订阅方（只有 `badgeCountsProvider` 与 `homeProvider` 订阅了总线），整理页靠 autoDispose 回页重建重读刷新。**不要直接给 OrganizeNotifier 加“收到 questions 事件就调 refresh()”**——`refresh()` 末尾调 `loadForm()`，会在用户正在整理页编辑表单时把表单重置掉。活页内刷新须先守门（例如只当 OCR 的题不是当前正在编辑的题时才刷新队列，或只刷新 OCR 状态行），由 M5/统筹另定。本模块只发事件，不碰 OrganizeNotifier。

### 启动接线

- `lib/app.dart`：`_QuizMasterAppState.initState` 里 `unawaited(OcrWorker.ensureStarted())`（启动时回收过期租约；启动失败不抛，绝不拖垮应用启动）。
- `flutter test` 下不启动（`Platform.environment['FLUTTER_TEST'] == 'true'` 时跳过），避免 widget 测试里后台轮询碰库；单测直接构造 OcrWorker，不走单例。

## 5. 队列表 CRUD（`lib/data/db_ocr_jobs.dart`）

仿 `db_recently_viewed.dart` 的单表 part 模式（`part of 'database.dart'`），不塞进 `db_backup.dart` / `db_questions.dart`。读/写走 Drift 类型化查询，不写 SQL 字符串；时间统一毫秒时间戳。

| 方法 | 行为 |
|---|---|
| `enqueueOcrJobIntoImpl` | 入队 + 去重（同一题 + 同一哈希的未完成任务已存在时返回它；`inputHash` 为 null 时不去重） |
| `claimNextOcrJobIntoImpl` | 领任务：最早创建的一条 `pending` 且退避已到期（`available_at` 为空或已到），同一事务内改 `running` + 写 `started_at`/`lease_until`；无可领返回 null |
| `reclaimExpiredLeasesIntoImpl` | 回收过期租约（running 且 `lease_until` 已过 → pending，清 started/lease）；返回行数 |
| `markOcrJobAttemptIntoImpl` | 发请求前 `attempt_count +1` |
| `retryOcrJobIntoImpl` | 可重试失败：回 pending + `available_at`（退避到期点）+ 记错误码/信息，清 started/lease |
| `failOcrJobIntoImpl` | 终态失败：failed + `completed_at` + 错误码/信息 |
| `completeOcrJobIntoImpl` | 终态完成：completed + `completed_at`（丢弃不走这里，走 fail + 丢弃码） |
| `ocrJobByIdIntoImpl` / `ocrJobsForQuestionIntoImpl` | 按 id / 按题读（按题最新在前，M5 看某题识别状态用） |

实例版（`AppDatabaseOcrJobs` extension）与静态转发（`AppDatabase.enqueueOcrJobInto` 等）与 `db_recently_viewed.dart` 同口径。`Value<int?>(null)` 是“把可空列写回 NULL”（与 `Value.absent()` 的“不动”不同），started/lease 的清除用它。

## 6. 测试结果

测试环境：`TMPDIR=$HOME/workspace/flutter-test-tmp`，`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`，`flutter test --concurrency=1`。只跑本模块测试 + 邻近回归，未跑全量（全量是 M7 的事）。

| 文件 | 通过 |
|---|---|
| `test/b13_ocr_client_test.dart`（新，19 项） | 19/19 |
| `test/b13_ocr_queue_test.dart`（新，18 项） | 18/18 |
| **本模块共计** | **37/37，全过** |

客户端 19 项覆盖：KeyStore 往返 + 空串清除；白边尺寸 100×50→160×80、四角纯白、原图居中、fraction=0 不变、坏图报 bad_image；括号校验（3 道真实 GLM 公式全过、不平衡 4 例、转义括号不计）；请求形态（layout_parsing + glm-ocr + data URI PNG、白边后尺寸、Authorization 头）；md_results 列表拼接；没 key 不发请求；401→api_key_invalid 不可重试；429→http_429 + Retry-After 45 秒；503→http_5xx 可重试、400→bad_params 不可重试；TimeoutException 与超 requestTimeout 都报 timeout；SocketException→network；200 缺 md_results→bad_response；切片不存在→file_missing；坏图不发请求；错误码表锁定（14 码、可重试集合）。

队列 18 项覆盖：入队字段 + 哈希 + 去重 + 无切片不建任务；成功应用（stem 切分、自动切分、contentVersion +1、completed、attempt 1、无可领返回 false）；租约回收（未过期 0、过期后 1 且清 started/lease）；没 key 只排队（pending、attempt 0、available_at +10 分钟、不写 failed、退避期内不领）；timeout 重试（退避 30 秒、429 按 Retry-After 45 秒、第三次成功）；api_key_invalid 一次即 failed；timeout 连败 4 次后 failed（退避 30/60/120 秒、attempt 4）；bad_image 不重试；hash 不一致丢弃（failed/hash_mismatch、题不动）；题目已删丢弃（question_deleted）；识别期间版本变了丢弃（content_changed，假识别器内模拟竞态）；人工改过只写 raw 候选（stem 不覆盖、contentVersion +1、hasPendingOcrCandidate true、候选题干正确、清标志后不再提示）；LaTeX 不平衡只写 raw（stem 空、未切分、不是候选）；完成发 DataChangeBus 事件；start/stop 后台循环自动跑完任务；start 幂等。

邻近回归（共享文件 database.dart / app.dart / collect_notifier.dart 被改过）：`b13_migration_test` + `b13_stem_splitter_test` + `m1_formula_renderer_test` + `collect_page_test` + `app_shell_test` + `b1_stage1_schema_test`，**191/191，全过**。

`flutter analyze`（9 个改动文件：3 个新服务 + db_ocr_jobs + database + app + collect_notifier + 2 个测试文件）：**No issues found**。

## 7. 真机调用验证（helper 端到端，少量）

用 `~/workspace/custom-connectors/custom.bigmodel/bin/glm_ocr_api.py`（走代理认证，不见明文 key）对尖峰同批 +30% 白边图调了 2 次（Dart 客户端本身只在单测里用假 HTTP 层验证，未调真实接口——按任务要求）：

| 图 | 耗时 | tokens | 结果 |
|---|---|---|---|
| `pad-a30-all/single01-q2.png`（双曲线） | 1.9 秒 | 289 | md 全对（题号 2.、公式 `$ 4 x^{2}-y^{2}=4 $`、A–D 全对），与尖峰第一轮逐字一致 |
| `pad-a30-all/double01-q5.png`（英语听力 Q1） | 1.2 秒 | 107 | md 全对，与尖峰第一轮逐字一致 |

- 两次耗时（1.9/1.2 秒）远小于客户端的单次请求超时 120 秒；tokens 与尖峰首轮完全一致（289/107），说明同一批图、同一接口、同一模型。
- 响应结构与客户端解析一致：`md_results` 是 string；`layout_details` 是列表的列表（外层页、内层块），单题 1 页 1 块，块含 `bbox_2d`/`label`/`content`/`index`/`width`/`height`（如 q2 的 bbox `[370, 45, 1605, 187]`）；`usage.total_tokens` 在。
- 两份 md 的 LaTeX 括号全部配对（`hasBalancedLatex` 的判定口径与实测一致；q5 无公式）。
- 未验证项：429/5xx 的真实服务端行为（单测只覆盖了客户端映射；真实限流需生产中观察，worker 按 Retry-After 退避）；Windows 真机（凭据管理器读写、ATL 构建）待 Meng 推送后验证。

## 8. 遗留与建议（给统筹）

1. **M5 接手点**：候选判定只用 `hasPendingOcrCandidate` / `pendingCandidateStem` / `clearOcrCandidateFlag`（都在 `lib/services/ocr_queue.dart` 底部）；raw 包格式见 §3；人工编辑保存时 `contentVersion +1`（见 §4 规则）；整理页活页内刷新须先守门（见 §4 事件节），勿直连 `refresh()`。
2. **M6 接手点**：OcrKeyStore 契约见 §2（键名 `'bigmodel_api_key'` 冻结）；设置页用 `hasApiKey()` 显示“已设置/未设置”，不要把 `getApiKey()` 的返回值显示或记日志；Win11 构建须确认 C++ ATL 已装。
3. **详情页重框后不重新入队**：本次入队点只有确认分框（`CollectNotifier.confirmSplit`）。详情页“重新框选”换切片后（`replaceQuestionBoxesAndSlice`），旧任务的哈希校验会丢弃旧结果，但不会自动为新切片建新任务——如需重框后自动重识别，由统筹另定（worker 侧只需在重框成功后调一次 `enqueueForQuestion`）。
4. **全量测试是 M7 的事**：本模块只跑了上述 8 个文件 228 项；`database.dart` 加了 part 与转发、`app.dart` 加了 `initState`，全量仍需 M7 复核。
5. **未改 `docs/decision-log.md`**：工作区里它已有其他模块的未提交改动，为避免冲突，D-108（M3：客户端 + 队列定稿——本报告 §2–§5 即条目内容）请统筹在合批时补记。
