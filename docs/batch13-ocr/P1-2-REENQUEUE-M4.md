# 十三批 P1-2 + M4 补充修复报告

日期：2026-11-18（子代理，P1-2 重框入队 + M4 歧义 UI）
范围：只做 P1-2 与 M4；P1-1 不动，P1-3 按接受关闭不动。未推送，未给 Meng 发邮件/消息。
`docs/decision-log.md` 未改，D-114 条目草稿见文末，由主代理追加。

## 1. 改动文件清单

生产代码（均在任务文件范围内，禁改文件未碰，见 §6 核对）：

| 文件 | 改动 |
|---|---|
| `lib/state/detail_notifier.dart` | P1-2：`applyReworkBoxes` 改 await 入队 + `ocrEnqueueFailed` 标志（load 后保留）；新增 `retryOcrEnqueue()`；新增 `acceptOcrCandidateWithReason()`（`acceptOcrCandidate()` 改为委托它）；新增测试缝 `enqueueOcrForTest`（见 §2.3） |
| `lib/modules/detail/question_detail_page.dart` | 失败横幅 `_ocrEnqueueFailedBanner`（Key `ocr-enqueue-failed-banner`，文案“题目已更新，OCR 未入队”+“重新入队”按钮）；`_acceptOcrCandidate` 按 reason 弹明确文案；新增 `_retryOcrEnqueue()` |
| `lib/modules/ocr/ocr_stem_section.dart` | M4：`_ambiguousBanner()`（Key `ocr-split-ambiguous-banner`）；顶层 `candidateRejectionMessage(String reason)`（7 个 reason 文案映射） |
| `lib/state/collect_notifier.dart` | 任务 c：`confirmSplit` 尾部批量入队后按 questionId 比对，未入队数非阻塞附在成功提示后；顶层 `@visibleForTesting ocrEnqueueMissedCount()` |
| `lib/state/organize_notifier.dart` | 任务 e：新增 `acceptOcrCandidateWithReason()`（`acceptOcrCandidate()` 改为委托它） |

测试：

| 文件 | 改动 |
|---|---|
| `test/b13_p1_2_reenqueue_m4_test.dart`（新增） | 14 个测试：重框入队失败/重试（真实库）3、接受原因透传 4、M4 横幅 4、批量提示 3 |
| `test/detail_page_test.dart` | 新增 1 个 widget 测试（入队失败横幅出现→“重新入队”后消失）；`setUp`/`tearDown` 接入队缝（成功假实现）；5 处重框确认轮询循环保留 |
| `test/b13_stem_correction_test.dart` | 仅两处注释修正：“重框入队是 fire-and-forget”已过时，改为 await 说明（断言与延时不动） |

## 2. 关键设计

### 2.1 P1-2：await 点与失败状态（GPT §5.2）

`DetailNotifier.applyReworkBoxes` 在框与切片落库（事务 + rename 成功）之后才入队：

```dart
await _enqueueForRework(repo.db, toEnqueue); // 默认 = enqueueOcrForQuestion，await 确认任务已持久化
```

- 只有 `worker.kick()` 是 fire-and-forget（它在 `enqueueOcrForQuestion` 内部调，生产代码不动）。
- 入队抛错只记标志，不改返回值：`ReworkOutcome` 仍是 `success`（框选结果已落库，不能因 OCR 失败谎称重框失败），页面不把“框选成功”等同于“OCR 已排队”。
- 失败标志两处存：`DetailState.ocrEnqueueFailed` + Notifier 私有 `_ocrEnqueueFailedQuestionId`。`load()` 重建 state 时按题 id 显式算 `keepEnqueueFailed` 再写进 `copyWith`——同题重读保留，切题/题不存在清除。横幅因此在重框成功提示之后仍可见。
- `retryOcrEnqueue()` 走同一入队路径（`_enqueueForRework`）：成功（含入队契约的 `null`——无切片不是失败）返回 true 并清标志、调 `_refreshOcrStatus`；抛错返回 false，标志保留，可再点重试。

### 2.2 批量入队提示（任务 c，P1-1 遗留 2）

`OcrWorker.enqueueForQuestions` 仍逐道吞错、只返回成功列表（未改）。调用点 `CollectNotifier.confirmSplit` 尾部：

- `worker == null`（单测/启动失败）→ 未入队数 = 全部题数；`enqueueForQuestions` 抛错（兜底）→ 同样按全部未入队报；宁可多报不可静默丢题。
- 提示 = 原成功文案 +（未入队 > 0 时）“其中 X 道题 OCR 未入队，可在详情页重新识别。”；`outcome.kind` 仍是 `done`，整理主流程绝不被 OCR 卡住。
- 计数是纯函数 `ocrEnqueueMissedCount(questions, jobs)`：按 `questionId` 比对返回任务行，缺的题数。

### 2.3 已知坑 M5 §七第二条：widget 测试挂住的根因与缝

现象（修前）：`flutter test --plain-name "重新框选"` 6 个测试，单跑全过，连跑时 P1-1 与 SR-P1-8 在“已重新框选，切片已更新”断言处失败。诊断过程（诊断补丁全部还原，无残留）：

- 第 1 个测试的入队全程走完（裁片→同哈希→insert→完成）；第 2 个测试只走到“inserting job”，挂在 `await db` / Drift impl 入口之间；挂点在多次运行间漂移（文件 IO 与库调用之间），不是单点死锁。
- 共同点：真实 Drift 是在 widget 测试的 fake async 下被 await。首个测试的 `runAsync` 恰好把开库链抢救出来，后续测试的入队不再完成；`tester.runAsync` 轮询加到 20 秒仍失败，是真挂住不是慢。
- Drift 本身用 `Future.sync` 调 sqlite（微任务可完成），挂点不在某一条 SQL；不值得继续追单行——真实库 await 本来就不属于 fake async widget 测试。

解法（任务 b 允许的“可 fake 的缝”，生产绝不改回 `unawaited`）：

```dart
@visibleForTesting
static Future<OcrJob?> Function(AppDatabase db, Question question)? enqueueOcrForTest;
```

- 位置在 `DetailNotifier` 内（允许改的文件），生产恒为 `null` → 走冻结契约 `enqueueOcrForQuestion`，await 不变；`applyReworkBoxes` 与 `retryOcrEnqueue` 都经 `_enqueueForRework`（缝优先，缺省走契约）。
- `detail_page_test.dart` 的 `setUp` 设成功假实现、`tearDown` 复位为 `null`；单个用例可在用例内改写缝（抛错模拟入队失败）。
- 真实入队路径由 `test/b13_p1_2_reenqueue_m4_test.dart` 的真实库 plain 测试覆盖（真实 async，无 fake 区）。
- 选用静态缝而不用改 `repository.dart`（文件范围外，且 `stem_correction.dart`  import 它，循环）。

### 2.4 M4 歧义横幅（GPT §4.2）

`OcrStemSection._ambiguousBanner()`，在 `question.ocrSplitStatus == OcrSplitStatus.ambiguous`（“存在歧义”）时显示，与编辑态无关，放在 header 行之后：

- 标题“识别结果待确认”，正文逐字用 GPT 文案：“识别内容包含无法确定的选项边界，请检查题干内容。”
- 独立内容状态：不混进队列七态——`deriveOcrStemStatus` 未改；“切分：存在歧义”小标签与状态 chip（如“识别完成”）原样保留，横幅只叠加。
- 位置在共用的 `OcrStemSection`，整理页与详情页自动都有。

### 2.5 接受失败原因透传（任务 e，P1-1 遗留 1）

`DetailNotifier.acceptOcrCandidateWithReason()` / `OrganizeNotifier` 同款：成功返回 `null`；`CandidateRejection.reason` 原样返回；其余失败返回 `'save_failed'`；无当前题返回 `'no_question'`。旧 `acceptOcrCandidate()` 改为 `== null` 委托，行为不变。

`candidateRejectionMessage(reason)`（`ocr_stem_section.dart` 顶层函数）：

| reason | 文案 |
|---|---|
| `question_deleted` / `no_question` | 题目已被删除，候选无法接受 |
| `no_candidate` | 没有待处理的识别结果 |
| `not_pending` | 这份识别结果已经处理过，不能重复接受 |
| `hash_mismatch` | 识别结果来自旧切片（已重新框选），已标记为过期，不能接受 |
| `slice_missing` | 切片文件不存在，无法核对候选来源 |
| `save_failed` / 其他 | 保存失败，请重试 |

详情页 `_acceptOcrCandidate` 改调透传版，失败时弹对应文案，不再一律“保存失败，请重试”。

## 3. 测试结果

环境：`TMPDIR=$HOME/workspace/flutter-test-tmp`，`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`，`flutter test --concurrency=1`。

### 3.1 模块测试

| 文件 | 结果 |
|---|---|
| `test/b13_p1_2_reenqueue_m4_test.dart`（新增，14 个） | 14/14 通过 |
| `test/detail_page_test.dart`（全文件，43 个，含新增横幅用例） | 43/43 通过 |

新增文件覆盖：

- 重框入队失败（关库模拟写库失败）：outcome 仍 success、框已替换、切片指新版本文件、`ocrEnqueueFailed` true；重开库后任务 0 条 → `retryOcrEnqueue()` true → 标志清除、任务 1 条 pending、`cropPath` 与新切片一致、`inputHash` 与切片文件一致。
- 重框入队成功：无标志，任务立即落盘（await 已确认，不用等 200ms）。
- 重试时切片已删：按契约 `null` 不算失败，标志清除，任务 0 条。
- 接受原因：DetailNotifier 成功→null，`question_deleted` / `no_candidate` / `not_pending` / `hash_mismatch`（且库里候选被标 stale）/ `slice_missing` 各有其值，无当前题→`no_question`；OrganizeNotifier 子集（成功 / hash_mismatch / no_candidate）；文案映射 7 输入全对且 5 个 reason 文案互不相同。
- M4：存在歧义→横幅 + GPT 文案 +“识别完成”chip 不变；自动切分/未切分→无横幅；存在歧义且无任务→横幅仍出现。
- 批量：`ocrEnqueueMissedCount` 纯函数 5 例；`confirmSplit` worker 未启动→kind done +“其中 2 道题 OCR 未入队，可在详情页重新识别。”；worker 已启动→kind done、无未入队后缀、库里任务 2 条。

### 3.2 邻近回归（M5 同款文件集 + 补充）

13 个文件一次跑完：`b13_stem_correction_test`、`organize_page_test`、`b13_stem_splitter_test`、`m1_formula_renderer_test`、`collect_page_test`、`app_shell_test`、`b1_stage1_schema_test`、`collect_notifier_test`、`b13_ocr_queue_test`、`b13_ocr_client_test`、`b13_migration_test`、`b13_ocr_settings_test`、`b13_p1_1_candidate_test`。

- **373/373 通过，EXIT=0**（日志 `~/workspace/batch13-work/p12-regression.log`）。
- `flutter analyze`：**0 问题**（修前 4 个，全在新增测试文件：1 个未用 import + 3 个下划线开头局部变量，已修）。
- 演示库 md5：跑前备份到 `~/workspace/demo-db-backup/quiz-master2.db.b13-p1-2-start`；跑后核对 `~/.local/share/quiz-master2/quiz-master2.db` 仍为 `8f7f9c64405dc6e484ac2bf8e5e1a807`，未变。

### 3.3 回归中途的环境插曲（已解决，不影响结论）

- 回归第一次跑中途服务重启，进程被杀；重跑时 `pdfium_dart` 原生资源构建失败——Linux x64 目标的 `native_toolchain_c` 只认 `clang`，而本机没有 clang（只有 gcc）。另一 apt 进程随后装上了 clang 18.1.3（我的 `apt-get install clang` 因 dpkg 锁失败，`which clang` 随后已是 `/usr/bin/clang`）。装好后回归一次通过。clang 是系统级环境修复，非代码改动。

## 4. D-114 条目草稿（请主代理追加到 docs/decision-log.md）

```
D-114（2026-11-18，十三批 P1-2 + M4，GPT 评审 §5.2/§4.2）：
- 重框入队改 await：DetailNotifier.applyReworkBoxes 在框与切片落库后 await
  enqueueOcrForQuestion() 确认任务已持久化，只有 worker.kick() 可
  fire-and-forget。入队失败不改 ReworkOutcome.success（框选结果保留），
  记 DetailState.ocrEnqueueFailed，load() 按题 id 显式保留该标志（切题清掉），
  详情页显“题目已更新，OCR 未入队”横幅 + “重新入队”按钮（走同一入队路径重试，
  成功后横幅消失；无切片返回 null 不算失败）。
- 批量入队诚实提示：CollectNotifier.confirmSplit 尾部按 questionId 比对
  OcrWorker.enqueueForQuestions 返回的任务行，未入队数非阻塞附在成功提示后
  （“其中 X 道题 OCR 未入队，可在详情页重新识别。”），worker 未启动按全部
  未入队报，outcome.kind 仍是 done，整理主流程不被 OCR 卡住。
- M4 歧义为独立内容状态：ocr_split_status = 存在歧义时，OcrStemSection 显
  “识别结果待确认”横幅（正文为 GPT 文案“识别内容包含无法确定的选项边界，
  请检查题干内容。”），不混进队列七态，deriveOcrStemStatus 不动。
- 接受失败原因透传：acceptCandidateStem 的 CandidateRejection.reason 经
  Notifier 的 acceptOcrCandidateWithReason() 原样返回（question_deleted /
  no_candidate / not_pending / hash_mismatch / slice_missing），其余失败
  'save_failed'，无当前题 'no_question'；页面按 reason 给明确文案，不再一律
  “保存失败，请重试”。
- 测试缝：DetailNotifier.enqueueOcrForTest（@visibleForTesting 静态注入，
  生产恒 null，走冻结契约）。真实 Drift 在 widget 测试 fake async 下连跑会
  挂住，详情页重框 widget 测试走缝；真实入队路径由真实库 plain 测试覆盖。
  生产绝不为过测试改回 unawaited。
```

## 5. 遗留问题

1. **`lib/modules/organize/organize_page.dart` 仍显示通用报错**：`OrganizeNotifier.acceptOcrCandidateWithReason()` 已就绪，但整理页不在本次文件范围内，其接受失败提示仍是通用“保存失败，请重试”。后续一处改动即可接上（调透传版 + `candidateRejectionMessage(reason)`）。
2. **Widget 测试的 SnackBar 定时器分属两个时间区**（本次踩到的坑，记下来免得后人再踩）：重框成功提示是在 `runAsync` 的真实时间区里建的（4 秒真实定时器），重试提示是在 fake 区建的（4 秒假定时器）。新横幅用例结尾假时间与真实时间各走了 5 秒才干净结束；只走一种会在用例结束后报 `hideCurrentSnackBar` 的 `mounted` 断言。
3. **切片自愈与重框并发竞跑**：打开详情页时 `_healSliceIfNeeded`（后台）与用户重框可能同时读写同一道题的切片字段。实测影响只限测试断言（`repo.saved.lastWhere` 取到的可能是自愈后保存的旧路径），生产行为不受影响（横幅/重试/入队均按题 id 与现切片走）。新横幅用例因此不用 `saved.lastWhere` 断言新切片路径，改断言 `replaceCalled` + `replacedBoxes`；版本化新路径由 P1-1 用例与本批 plain 测试覆盖。
4. **B13 旧测试写真实数据目录**：`b13_stem_correction_test` 与 `b13_p1_1_candidate_test` 的部分用例把切片写进真实数据目录（未设 `testDataDirectory`），是既有行为，本次未动；本批新增测试文件一律用独立临时目录，不写真实目录。
5. 本次未验证 Win11 真机；代码未推送，需 Meng 批准后按既有流程推。
