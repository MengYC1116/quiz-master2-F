# M5 纠错 UI 交付报告（quiz-master2 十三批）

- 日期：2026-11-18
- 执行员：M5
- 范围：只做 M5（整理工作台 + 详情页纠错 UI，共用同一套编辑器组件）。未碰其他模块，未发邮件/消息，未推送代码。
- 依据：M1-RENDERER-POC §八、M3-QUEUE §3/§4、M4-SPLITTER §二、gpt-consult-ocr-implementation §3、decision-log D-103～D-108。

## 一、改动文件清单

### 新增（5 个）

| 文件 | 职责 |
| --- | --- |
| `lib/modules/ocr/ocr_stem_status.dart` | 纯状态推导：`OcrStemStatus`（7 态）+ `deriveOcrStemStatus(question, {jobs, hasApiKey, now})` |
| `lib/modules/ocr/formula_crop.dart` | 纯函数 `cropFormulaImageBytes({sliceBytes, ocrRaw, formulaIndex})`：按 `ocr_raw.layout_details` 里 label 含 `formula` 的块 bbox 从切片裁公式小图；裁不到返回 null（调用方用整张切片）。永不抛错。实测 GLM 样本里只有 `text`/`image` 块、无 `formula` 块，所以通常走整张切片回退。 |
| `lib/modules/ocr/stem_correction.dart` | 共享保存规则 + 入队 helper：`applyManualStemEdit` / `applyCandidateStem` / `dismissOcrCandidateFlag` / `candidateStemForQuestion` / `enqueueOcrForQuestion` |
| `lib/modules/ocr/stem_editor.dart` | 唯一编辑器组件 `StemEditor`（两页共用） |
| `lib/modules/ocr/ocr_stem_section.dart` | 共享区段 `OcrStemSection`（两页共用）：标题 + 状态 chip + 只读渲染 + 候选横幅 + [编辑题干][重新识别] |

### 修改（6 个 lib + 1 处既有 bug 修复）

| 文件 | 改动 |
| --- | --- |
| `lib/modules/ocr/question_content.dart` | 新增 `blocksToMarkdown`（`parseQuestionContent` 的逆操作；`ImageFallbackBlock` 拼回时丢弃）。代码块拼回时去恰好一个尾换行（解析时 code 含围栏闭合前的换行，不去会每次多一个空行）。 |
| `lib/data/repository.dart` | `QuestionRepository` 新增 `ocrJobsForQuestion(id)` 与 `hasOcrApiKey()`（只答“有没有 key”，不读 key）。两者失败兜底（`[]` / false），OCR 状态永远拖不垮页面。 |
| `lib/state/organize_notifier.dart` | `OrganizeState` 加 `ocrJobs`（默认 `[]`）+ `hasOcrApiKey`（默认 false）；`refresh()` 尾部 best-effort 刷新 OCR 状态；新增 `refreshOcrForQuestion` / `candidateStemFor` / `saveStemEdit` / `acceptOcrCandidate` / `dismissOcrCandidate` / `rerecognizeCurrent`（均返回 bool）。 |
| `lib/state/detail_notifier.dart` | `DetailState` 加 `ocrJobs` + `hasOcrApiKey`；`load()` 尾部 best-effort 刷新；新增 `refreshStemStatus` / `candidateStemFor` / `saveStemEdit` / `acceptOcrCandidate` / `dismissOcrCandidate` / `rerecognizeCurrent`；**`saveEdit()` 修了一个既有 bug**：原来用全新 `Question(...)` 重建，会静默丢掉 5 个 OCR 字段（`ocrRaw` / `ocrStem` / `ocrSplitStatus` / `ocrManualEdited` / `contentVersion`），现在从 `base` 带上；**`applyReworkBoxes` 成功后自动为新切片建 OCR 任务**（见 §五）。 |
| `lib/modules/organize/organize_page.dart` | 左窗格“修框切片”折叠区下方插入 `OcrStemSection`（`ValueKey('ocr-stem-${q.id}')`）；订阅 `DataChangeBus`，按 §四守门；接纠错四个回调。 |
| `lib/modules/detail/question_detail_page.dart` | 题目图下方插入同一 `OcrStemSection`（同 key 方式）；订阅 `DataChangeBus`，按 §四守门；接纠错四个回调。 |

### 测试（新增 1 个文件）

- `test/b13_stem_correction_test.dart`：41 个测试（见 §六）。

## 二、编辑器组件位置与复用方式

- 只做一套：`StemEditor`（`lib/modules/ocr/stem_editor.dart`）+ 外壳 `OcrStemSection`（`lib/modules/ocr/ocr_stem_section.dart`），都在 `lib/modules/ocr/`。
- 两页复用方式：整理页在每道题的切片图正下方、详情页在题目图下方，各放一个 `OcrStemSection`，传 `question` / `jobs` / `hasApiKey` / `sliceBytes` 与四个回调（`onSaveEdited` / `onAcceptCandidate` / `onDismissCandidate` / `onRerecognize`）。回调返回 `Future<bool>`，false 时编辑器保持打开（保存失败不闪退）。
- 点“编辑题干”在切片下方原地展开，不跳页面。草稿是段列表：普通文字段 = 多行 TextField 直接改；公式块 = `FormulaView` 渲染 + [恢复为原图] / [删除]；代码段 = 等宽 TextField，缩进保留（D-105 验证在测试里）。
- “恢复为原图”语义（本批约定）：保存时该公式从 `ocr_stem` 里拿掉，于是只读区回退到原图显示（原图切片本来就在区段正上方）；公式原文仍在 `ocr_raw.md_results` 里，可经重新识别恢复。界面文案为“已恢复为原图：保存后该公式以原图显示，可重新识别恢复”，并有 [恢复渲染] 可反悔。
- 候选预览：`_showCandidate` 时当前草稿渲染 vs 候选渲染并排，[用新结果替换] / [忽略]；先预览、再确认，绝不直接替换。
- LaTeX 绝不外露：界面、复制文本、报错、日志均无 LaTeX 源码（测试 §六有断言：渲染后文本中找不到 `frac`；编辑器各态同查）。

## 三、状态推导规则（`deriveOcrStemStatus`）

7 态，优先级如下（`OcrStemStatus.label`）：

1. `ocrManualEdited == true` → **已手动修改**（哪怕另有任务在跑）。
2. 最新一条任务（按 `createdAt`）为 running → 有 key 才“识别中”，无 key 一律“等待设置 API Key”。
3. 最新一条为 pending → 无 key “等待设置 API Key”；有 key 且 `availableAt` 在未来 → “稍后自动重试”；否则“等待识别”。
4. 最新一条为 failed → `api_key_missing` / `api_key_invalid` → “等待设置 API Key”，其余 → “识别失败”。
5. 最新一条为 completed → “识别完成”。
6. 无任务 → 有题干或有原始结果 → “识别完成”（只有 raw、无可用题干 = LaTeX 不平衡的原图回退，仍算完成）；无 key → “等待设置 API Key”；否则“等待识别”。
7. 候选标志不是状态：有新候选时另显“有新的识别结果”横幅（用 M3 的 `hasPendingOcrCandidate` 判定，不自己比文本）。

- 切分状态与题干状态分开显示：识别完成时另显“切分：自动切分 / 未切分 / 存在歧义 / 人工调整”（`StemSplitStatus.label`）。
- 按钮：[编辑题干]（主操作）常驻；失败时 [重新识别] 显示为“重试”；人工改过后点重新识别先弹确认框（“这道题干已手动修改过。重新识别会产生新的候选结果，原内容会保留，等你预览确认后才替换。”）。

## 四、活页内刷新守门规则（M3 警告，必守）

两页 `_onDataChange`（`DataChangeBus` 的 `questions` 事件）与 `StemEditor.didUpdateWidget` 共同守门：

1. 事件的 `questionId` 为空（批量/备份）：当前不在编辑时只刷新当前题的 OCR 状态行；编辑中整条跳过。
2. 事件的题 = 当前正在纠错编辑器里编辑的题：**绝不调 `refresh()` / `loadForm()` / `refreshOcrForQuestion` / `load()`**；只经 `candidateStemFor(id)`（无状态纯读，不碰 Notifier）取候选，编辑器里只显“有新的识别结果”横幅，草稿原封不动。
3. 事件的题是别的题：调 `refreshOcrForQuestion(id)`（整理页）/ `refreshStemStatus()`（详情页，仅当前题；别题事件忽略）——只换队列行/题行 + 任务行 + key 有无，表单值与 `formResetKey` 不动。
4. 组件层：`StemEditor.didUpdateWidget` 只有 `question.id` 变了才重建草稿；同题的候选/状态更新只重绘横幅，不动草稿。
5. 状态刷新本身是 best-effort：`refresh()` / `load()` 尾部用 `unawaited(_refreshOcrStatus())`，读不到/挂起都不挡主流程（见 §七的两个教训）。

## 五、重框自动重识别的接线点

- 详情页 `DetailNotifier.applyReworkBoxes(newLayer1, pageAbs)` 成功路径：事务替换框 + 切片 rename + `evictCachedFileImage` 之后、最终 `load()` 之前，重读该题（`repo.questionById`），调 `enqueueOcrForQuestion(repo.db, updated)`（M3 入队接口：切片 SHA-256 哈希 + `enqueueOcrJob`）。
- 旧结果由 worker 应用前的哈希校验丢弃（新切片哈希不同 → `hash_mismatch`）；人工改过的内容仍走候选保护（写回分层：manual-edited 只产候选）。
- 入队是 fire-and-forget（`unawaited`）：入队失败/挂起不影响重框成功本身（OCR 是锦上添花）。见 §七第二条。
- 整理页重新识别：`rerecognizeCurrent` 调同一入队接口，成功返回 true、页面提示“已重新加入识别队列”；失败（无切片等）返回 false、提示“重新识别失败”。

## 六、测试结果

测试文件：`test/b13_stem_correction_test.dart`，**41/41 通过**（Flutter 3.47.9 / Dart 3.13.7；`TMPDIR=$HOME/workspace/flutter-test-tmp`，`LD_LIBRARY_PATH=…/onnxruntime-1.4.1/linux`，`--concurrency=1`）。

分组：状态推导 10 · 拼回往返 4 · 保存规则 4 · 公式裁图 3 · 区段/编辑器 widget 11 · 整理页守门 widget 1 · 整理页 Notifier 方法 3 · 详情页 Notifier 方法 2 · 重新识别与重框入队（真实库）3。

覆盖点：7 态全覆盖（含“无 key 绝不显示识别中”）；候选预览/接受/忽略；编辑中 OCR 返回只显横幅不刷草稿（守门 widget 测试：改后题干仍在、横幅在、新题干不出现；关编辑器后再来事件才刷新）；重框成功自动入队（pending 任务、cropPath `slices/q1.png`、inputHash 与新切片 SHA-256 一致；旧切片文件缺失时重框仍成功、新切片照常入队）；整理页重新识别建 pending 任务且哈希对得上切片；`saveEdit` 保留 OCR 字段；LaTeX 不外露。

邻近回归（同环境，同批跑）：

- `test/detail_page_test.dart` + 本文件：82/82 通过。
- `test/organize_page_test.dart` `test/organize_notifier_test.dart` `test/detail_notifier_test.dart` `test/m1_formula_renderer_test.dart` `test/b13_ocr_queue_test.dart` `test/b13_ocr_client_test.dart` `test/b13_stem_splitter_test.dart` `test/collect_page_test.dart`：287/287 通过。
- `flutter analyze`（12 个改动文件 + 测试文件）：No issues found。
- 演示库 md5 校验：备份 `~/workspace/demo-db-backup/quiz-master2.db` 与运行库均为 `8f7f9c64405dc6e484ac2bf8e5e1a807`（标准 v1），未被测试改动。

未跑全量（全量是 M7 的事）。

## 七、回归中发现并已修的两个问题（写下来供 M7/复核参考）

1. **仓库读超时不能用 `.timeout()`**：`QuestionRepository.ocrJobsForQuestion` 最初加了 5 秒超时；widget 测试的 fake async 里，未完成的 Timer 在测试结束时按“仍有待处理 Timer”判失败，`detail_page_test` 41 项全灭。已去掉超时，改由调用方不 await（`unawaited(_refreshOcrStatus())`）。OCR 状态加载是装饰性 best-effort，读不到就保持旧值，不挡页面。
2. **重框入队不能 `await`**：`applyReworkBoxes` 里 `await enqueueOcrForQuestion(...)` 在 widget 测试里会挂住（真实库在 fake async 下永不完成，D-88 同款原因），重框成功提示出不来，`detail_page_test` 两项重框用例失败。已改为 `unawaited`；自家重框测试改为入队后等 200ms 再断言任务行。
3. 另修一处测试时序：`OrganizeNotifier.build()` 有 microtask 首查 `refresh`，与测试里手动 `refresh()` 竞跑，`formResetKey` 读数靠运气——测试里先沉淀微任务再读数（生产代码无此问题）。
4. 另修一处生产代码：`blocksToMarkdown` 代码块拼回多一个尾换行（见 §一）。

## 八、保存规则（按 M3 §4，集中实现在 `stem_correction.dart`）

- 人工编辑保存：`applyManualStemEdit`——题干写进 `ocr_stem`，`ocr_split_status` 写“人工调整”，`ocr_manual_edited = 1`，`content_version + 1`，候选标志清掉。
- 接受候选：`applyCandidateStem`——候选题干写进 `ocr_stem`，切分状态由对候选题干重跑 `splitStem` 写回，`ocr_manual_edited` 保持 1，`content_version + 1`，raw 候选标志清掉。
- 忽略候选：`dismissOcrCandidateFlag`——只清标志，`content_version + 1`（raw 变了），题干不动；无候选时原样返回。
- 整理/详情的普通表单保存不碰 `contentVersion`（只有 OCR 自动应用与人工题干保存才 +1）。
- 三条跨模块规则已守：原图永远是最终依据（区段正上方始终是切片原图；“恢复为原图”回退原图；渲染失败回退原图）；OCR 自动结果不覆盖人工结果（manual-edited 只产候选，见 §三第 1 条与 §五）；没 key、没网不影响题目的保存、查看、复习、编辑（状态读失败兜底；入队失败只影响 OCR，不影响主流程）。
