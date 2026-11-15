# quiz-master2 第二次自审（SELF-REVIEW-2）

- 日期：2026-11-15
- 范围：Batch 5 修复后的全代码通读复核（Batch 5 改动过的代码 + 全部 B5 新增测试）
- 方式：6 组并行分片通读，只审不改；分报告见 `SELF-REVIEW-2-DATA.md`、`SELF-REVIEW-2-COLLECT.md`、`SELF-REVIEW-2-WRONGBOOK.md`、`SELF-REVIEW-2-SERVICES.md`、`SELF-REVIEW-2-DOCS.md`、`SELF-REVIEW-2-TESTS.md`；本报告为去重合并版（跨组合并 5 处：SR2-1、SR2-2、SR2-3、SR2-8、SR2-9；各组“新测试质量”小节中与 TESTS 组审计重复的缺口已折入对应产品项，不另编号，另有 14 处 TESTS 组未覆盖的测试缺口单独编号为 SR2-65～SR2-78）
- **结论：共 78 项：P0 0 项，P1 13 项，P2 65 项。** 其中 P1 有 3 项是 Batch 5 引入的新回归或同类复活（SR2-3、SR2-7 的一部分），其余为 Batch 5 未修完、未修对或修后留下的缺口。
- 验证：`flutter analyze` 0 问题；全量测试 **778/778** 通过（约 4 分 43 秒，日志 `~/workspace/demo-db-backup/full-test-20261115.log`；但 expanded 日志缺 10 个文件的路径行，逐文件归属不完整——见“验证说明”）；Linux Release 构建成功（本次自审由协调员补跑，clang 18.1.3）；演示库 md5 全程 `8f7f9c64405dc6e484ac2bf8e5e1a807`（v1、9 题、3 学科），未被改动；未改任何代码，未 commit/push。

## 验证说明

- 全量测试 778/778 的总数可信（计数器走到 +778、`All tests passed!`、静态用例声明数 773 + 循环生成与 778 量级吻合），但 expanded 日志缺 10 个文件的路径行（含 `b5_p2_data_test.dart`、`pdf_render_service_test.dart`），且 pump-heavy 用例会重复打印同一行，故“PDF 组 13 项本次一次通过”等逐文件结论只能以总数佐证，缺逐文件日志行；待 clang 恢复后（已恢复）定向复跑补证。Linux Release 构建在本次自审期间由协调员补跑成功，补上了 TESTS 组因 clang 丢失未能执行的部分。
- SR-P2-11 的 Windows 文件锁定分支、SR-P0-2 的真机列表行为仍需 Win11 真机复核（Linux 无法模拟）。

## P1（13 项）

### SR2-1 — SR-P1-4 未修完：图片分支尾部 upsert 仍在 try 之外，写库失败逃出 `enqueue`（另含 EXIF 分支复活与空 catch 吞错两个亚型）

- 位置：`lib/services/import_service.dart:359`（图片分支末尾 `await _db.upsertCollectTask(task)`，importing → needBox）；调用点 `lib/modules/collect/collect_page.dart:291`（`service.enqueue` 无 try 包裹）。亚型 (a) `:227/:237`（超限/超空间失败 upsert 藏在 `try {} catch (_) {}` 里）；亚型 (b) `:294/:313`（EXIF 失败分支）。
- 现象：B5 只修了 PDF 分支。图片分支写库失败时 `DatabaseException` 直接逃出 `enqueue`：本任务停在 `importing`（无失败标记、无法重试），同一批后面的文件不再处理——与 SR-P1-4 原文失败模式一字不差。亚型 (a)：upsert 抛错被空 catch 吞掉，库里任务仍停在 `importing`，内存返回的却是 failed——库与返回结果不一致，收集页 `_load` 读库后任务仍显示“导入中”，无法重试。亚型 (b)：`canDecodeImageBytes` 为假时先删目录、再 `_failed`、再 upsert；若这次 upsert 抛错，控制流落入外层 `catch (e)`（`:336` 起），被当成“读盘/写盘等不明确的原因”走降级兜底，继续把任务写成 needBox——目录已被删、页图不存在，任务变成“待框选但打不开”。
- 证据：数据组探针 P-A（BEFORE UPDATE 触发器让一切写 needBox 的 UPDATE 失败，`enqueue(['test/fixtures/photo.jpg'])` 直接抛错，未返回失败任务；同一触发器下 PDF 分支能正常返回 failed 任务）；收集组代码走读确认亚型 (a)(b)。B5-P1-DATA.md 遗留第 2 条自己记了图片尾部这一处，但未修。
- 修的方向：图片尾部 upsert 与 PDF 分支同款包进 try/catch 走 `_failAndClean`（或在 `enqueue` 每文件循环外包一层 try，把异常转成该任务的 failed 行并继续下一个文件）；超限/超空间/复制/EXIF 各失败分支的 upsert 各自包 try，失败只返回内存 failed 任务；EXIF 分支把“已判定解不开图片”（目录已删）与“读盘/写盘失败”（原图还在）分开处理，前者失败后不得复活成 needBox。
- 测试缺口：`import_service_p1_fixes_test.dart` 的 P1-4 组只钉了 PDF 尾部 upsert 失败，图片分支尾部与 `_failAndClean` 自身写库失败无用例（见 SR2-60 的一部分）。
- 严重度：**P1**。

### SR2-2 — SR-P1-4 未修完：`_failAndClean` 自身的写库无兜底，9 处调用点只有尾部 1 处有保护

- 位置：`lib/services/import_service.dart:463-474`（`_failAndClean`，`:472` 的 `await _db.upsertCollectTask(failed)` 无 try）；调用点 `:380`、`:382`、`:386`、`:389`、`:392`、`:406`、`:424`、`:426`、`:430`（`_importPdf` 内全部早期失败返回）与 `:452`（尾部，唯一有 try/catch 的一处）。
- 现象：`_failAndClean` 是全部失败路径的公共出口，但它自己的 upsert 失败即抛错。只有尾部路径（`:451-459`）包了 `try { return await _failAndClean(...) } catch (_) { return _failed(...) }`；其余 8 处早期返回（读页数失败、加密/损坏、0 页、超 20 页、空间不足、渲染失败）都是裸 `return _failAndClean(...)`。库坏到 failed 行也写不进去时，异常逃出 `_importPdf`——而 `enqueue` 里 `final done = await _importPdf(...)`（`:287`）本身不在 try 里，只有它后面的收尾 upsert 有兜底——于是异常继续逃出 `enqueue`，整批中断、任务卡 `importing`。B5 报告称“再失败也只返回内存里的 failed 任务”，该保证只对尾部路径成立。
- 证据：数据组探针 P-B（BEFORE UPDATE 触发器让一切写 `failed` 的 UPDATE 失败；假 PDF 引擎抛 `PdfCorruptException`；`enqueue` 应返回 1 个 failed 任务，实际直接抛错）；收集组探针 C（同款触发器，损坏 PDF 进 `_importPdf` → `_failAndClean` → 触发器炸 → `enqueue` 抛出 `DatabaseException`）——两组独立复现一致。
- 修的方向：`_failAndClean` 内部把 upsert 包进 try，失败时返回内存里的 `_failed(task, error)`（目录已删，任务行写不进是预期内的降级）；或在 `enqueue` 的 `_importPdf` 调用点包 try/catch。一处修、九处受益。
- 严重度：**P1**（触发条件比 SR2-1 更苛刻——需失败路径 + 写库同时失败）。

### SR2-3 — B5 引入的新回归：详情页重框事务失败时删掉题的唯一一份切片

- 位置：`lib/modules/detail/question_detail_page.dart:361-368`（写盘）与 `:382-396`（失败处理）。
- 现象：重框先把新裁切片原地写到 `sliceRel = ImportService.sliceRelative(q.id)`（`'slices/$questionId.png'`，与旧切片同一文件路径，无临时名、无旧文件备份），再调 `replaceQuestionBoxesAndSlice` 事务。事务失败时 catch（`:393-394`）删掉 `sliceAbs`——删的正是刚覆盖掉旧图的唯一一份切片。库内 `slice_path` 仍指向该路径，题从此无图，详情页走“图片缺失”。修前（B5 之前）：事务失败只留“新图配旧框”的错配，图还在、框还能看；修后：图直接没了，且无任何恢复入口（切片只能重框再生，但重框页本身依赖页图，不依赖切片——仍可重框一次恢复，代价是一次人工重框；若页图也不在则彻底无法恢复）。`_confirmSplit` 的同款清理（`collect_page.dart:568-573,676-682`）删的是新题 id 的新文件，无此问题——只有详情页是“同路径覆盖旧文件”。
- 证据：代码直接可读（`:368` 原地覆盖写盘；`:384-391` 事务调用，失败进 catch；`:393-394` 删文件）。B5-P2-COLLECT §5 自认此取舍（“如需‘失败恢复旧切片字节’，可改为写盘前先读旧字节、失败时写回——协调员定夺”）。
- 修的方向（协调员定）：切片先写临时文件（如 `slices/<qid>.tmp-<随机>.png`），事务成功后再 rename 到正式路径；注意 `evictCachedFileImage(sliceAbs)`（`:373`）在事务前已清缓存，改临时名后缓存失效点也要相应后移。备选：写盘前先读旧切片字节、失败时写回。
- 测试缺口：B5 的 P2-3 回归测试夹具里 `slices/q1.png` 事先不存在（只断言“新切片已删、框与题不动”），未覆盖“有旧切片”的真实情况，旧切片被毁的行为未被任何测试钉住。
- 严重度：**P1**（触发需事务失败，罕见，但一旦触发即丢唯一图片文件）。

### SR2-4 — 确认拆题丢弃有框页上的独立题内框

- 位置：`lib/modules/collect/collect_page.dart:599`（`_confirmSplit`）。
- 现象：编辑器里可见、可拖、可删的独立题内框（`standaloneInner`，无父框的 stem/option/figure），只要它所在页有题级框、被确认拆题，就会静默消失：不挂到任何题、不进保留任务、原任务删除后无处可去，全程无提示。这与 B3 决定“手动 2 层框保留不动、不删数据”（SR-P1-6 引述）直接冲突，是 P1-6 同类的残留，B5 未覆盖。
- 证据：收集组探针 A（草稿 `{b1: layer-1}` + `{orphan-stem: layer-2, 无 parentBoxId}` 同在第 1 页；确认后 `boxesByQuestionId ids: [b1]`，`orphan-stem` 不在任何题的框里）。代码：`boxesByQuestionId[qid] = [box, ...?result.inners['$p:${box.id}']]` 只取有父框的内框；`result.standaloneInner` 在 `_confirmSplit` 里只在“未框页保留”分支出现（`:674`），有框页的独立内框没有任何去向。独立内框的产生路径并不罕见：非内框模式下画 stem/option/figure 框、中心落在任何题级框外即进 `standaloneInner`（`box_editor.dart:968-984`）；YOLO 孤儿框与归一化后无主的旧框同样进这里。
- 修的方向：三选一并补测试——(a) 确认时把独立内框按中心点挂到最近/命中的题下（与 `_confirmPendingType` 的落点规则一致，协调员推荐此项）；(b) 有独立内框时确认前弹提示，问用户丢弃或先挂到某题；(c) 至少把独立内框随保留任务保留（无未框页时无保留任务，此路不通，需另议）。测试应钉：有框页独立内框确认后仍在题的框里（B5 的 P1-6 测试只覆盖有父框的 `inners`，未覆盖此分支）。
- 严重度：**P1**（静默丢用户手画的数据）。

### SR2-5 — 队列弹窗内连续两次批量操作，第二次用旧快照抹掉第一次的改动

- 位置：`lib/modules/organize/organize_page.dart:2266-2273`（`_QueuePopupState._batchTagRedo`），对照 `:2283-2317`（`_batchAddFolder`）。
- 现象：B5 的 P1-7 修复只保证了“打开队列时快照新鲜”，没保证“弹窗内连续批量操作之间快照新鲜”。`_batchAddFolder` 保存后用 `setState` 把新文件夹同步回弹窗内的 `_questions`，但 `_batchTagRedo` 保存后完全不更新 `_questions`。同一次弹窗内先点“批量打标签 #需重做”、再点“批量加入该文件夹”，第二次操作拿的仍是打标签前的旧 `Question` 做整行覆盖，标签被抹掉。`_batchConfirm` 同样从 `_questions` 快照取行，先打标签再批量确认也会丢标签（同一根因）。
- 证据：收集组探针 B（三题仓库，选 q1 → 批量打标签 → 批量加入该文件夹（默认 f1）→ 关闭队列；输出 `q1 tags=[] folders=[f1]`）。
- 修的方向：`_batchTagRedo` 保存后同步更新 `_questions`（与 `_batchAddFolder` 同款 `setState` map），或批量操作前按 id 重读最新行再合并；测试应钉：同一弹窗内“打标签 → 加文件夹 → 关闭”后标签与文件夹都在（B5 的 P1-7 测试只做到单次批量操作 + 关闭）。
- 严重度：**P1**（P1-7 同类静默覆盖；用户在一次弹窗里连做两次批量操作是自然流程）。

### SR2-6 — `_saveCurrent` 只写库、不同步内存 `_queue`，切题往返后保存会覆盖已落盘的改动

- 位置：`lib/modules/organize/organize_page.dart:313-320`（`_saveCurrent`）、`:326-332`（`_goTo`）、`:438-450`（`_jumpToQuestion`）、`:456-463`（`_applyQueueSort`）；表单读数 `:223-257`（`_loadForm` 读 `_current` 即 `_queue[_index]`）。
- 现象：B5-P1-7 报告末尾自认的遗留，属实且可复现。`_saveCurrent` 只写库，`_queue` 里仍是旧对象；`_goTo` / `_jumpToQuestion` / `_applyQueueSort` 保存后都不刷新 `_queue` 就调 `_loadForm`。改 q1 文件夹与答案 → 切到下一道（已落盘）→ 切回来，表单从 `_queue` 读出旧值；此时点“保存草稿”，`_formQuestion` 按旧表单 state 整行写回，把已落盘的文件夹与答案覆盖回旧值。
- 证据：收集组探针 D（先切题，`repo.saved` 里 q1 已有 `f2` 与 `答案：1`；切回来点“保存草稿”，输出 `lastSave folders=[] answer=null`）。B5 只在 `_openQueue` 里单点打补丁（把表单行写回 `_queue`），其余三条切题路径仍是旧形状。
- 修的方向：按 B5-P1-7 报告自己建议的根治方案——在 `_saveCurrent` 内统一把保存后的行写回 `_queue`（或切题时 `_refresh`）；测试应钉：改表单 → 下一道 → 上一道 → 保存草稿，文件夹与答案仍在。
- 严重度：**P1**（静默覆盖已保存的改动，与 P1-7 同级；触发只需一次切题往返）。

### SR2-7 — 目录“移动文件夹”目标下拉用陈旧值，换科或删目标文件夹后触发 DropdownButton 断言

- 位置：`lib/modules/wrongbook/wrongbook_directory.dart:176`（`value: _moveTargetId`）→ `lib/modules/wrongbook/wrongbook_page.dart:1501-1536`（`_styledDropdown` 是真的 `DropdownButton`）；状态字段 `lib/modules/wrongbook/wrongbook_page.dart:202`（`String _moveTargetId = '__top__'`）；赋值只在 `wrongbook_directory.dart:186`（下拉 `onChanged`）。
- 现象：`_moveTargetId` 在任何导航/刷新/删除路径上都不复位：`_openDirectory`（只清 `_selectingMove/_moveSelection/_renamingId/_draggingId` 等，不碰 `_moveTargetId`）、`_openShelf`、`_load`、`_deleteFolderConfirmed` 均不重置它。于是：(1) 换科复现（无需删除，三步即达）：A 科目录打开“选择文件夹”，目标下拉选某顶层文件夹 X；回书架进 B 科目录，再点“选择文件夹”→ 移动条重建时 `_moveTargetId` 仍是 A 科 X 的 id，不在 B 科的下拉选项里，debug 下抛断言，release 下拉显示异常——与 SR-P0-2 同一契约、同一后果。(2) 删目标复现：移动条开着、目标已选 X 时，直接点 X 行的“删除”并确认 → `_load` 后 `_selectingMove` 仍为 true，移动条带着已删的 id 重建，同样断言。把 X 拖进别的文件夹（不再是顶层）后也有同样效果。二次伤害：即使下拉被绕过，点“移动”时 `_moveOneFolder`（`wrongbook_page.dart:894`）用无 `orElse` 的 `_folders.firstWhere((x) => x.id == targetParentId)` 查目标，目标不存在即抛 `StateError`；`_moveSelected` 与 `_applyDrop` 两处调用方都没有 try/catch。
- 证据：全树 `grep _moveTargetId` 只有 4 处（定义、移动条 value、移动条 onChanged、`_moveSelected` 取值），无任何一处复位或校验（协调员已复核确认）；对照同一页的批量条 `_buildBatchBar`（`wrongbook_list.dart:535-538`）已有显式防线——同类修复只做了一处，另一处漏了。
- 修的方向：与批量条同款：在 `_buildMoveSelBar` 里把 `_moveTargetId` 先对当前科顶层文件夹校验，无效时回落到 `'__top__'`；同时 `_moveOneFolder` 的目标查找改 `firstWhereOrNull`（或 `orElse` 抛可提示的错），`_moveSelected` 汇总提示；另在 `_openDirectory`/`_openShelf`/`_deleteFolderConfirmed` 里把 `_moveTargetId` 复位为 `'__top__'`。修后加一测：A 科选目标 → 进 B 科开移动条不断言；选定目标后删掉它 → 移动条不断言且回落到“移到顶层”。
- 严重度：**P1**（SR-P0-2 同类问题在另一处复活）。

### SR2-8 — 决定文档仍写“超限只提示不硬性拦截”，已被 Batch 5 的 SR-P1-14 代码改动推翻

- 位置：`docs/quiz-master2-mo-kuai-bian-jie-hua-fen.md:85`（§4.2）与 `docs/decision-log.md:133`（D-15）：“PDF 上限 50MB、图片上限 20MB，超限只提示不硬性拦截/不硬拦”。
- 现象：Batch 5 按已定修法 (a) 把图片 20MB 也改成了硬判，上述两处文档仍写旧口径。按文档行事会认为超限文件仍可导入，与现状相反。
- 证据：代码 `lib/services/import_service.dart:213-225`（“单文件大小上限：PDF 50MB / 图片 20MB，复制前 [硬判]”“不再只提示不执行”，超限进 `failed` 任务）；收集页横幅已同步改写。B5-P1-DATA 只改了代码与横幅，未改这两处文档；SR-P1-14 本身不是文档项，故无报告认领。
- 修的方向：两处都改为“PDF 50MB / 图片 20MB，超限硬判进失败任务（可先压缩再重选）”；并核对 `oversizeHint` 的“提示”定位（选文件时的事前提示仍在，`import_service.dart:148-152`）。改文档即可，不动代码。
- 严重度：**P1**（按文档行事会改错代码）。

### SR2-9 — `demoQuestions()` 已删，三处文档仍写它存在

- 位置：`docs/decision-log.md:35-37`（D-04 末尾补注，Batch 5 第四阶段 SR-P1-34 所加）：“`demoQuestions()` 仅作定义保留，目前没有任何生产调用方，上面 9 道题是演示库 v1（老库）的口径”；`README.md:61`：“演示数据定义：数学/英语/政治各 3 道大学题（`demoQuestions()`，共 9 道）+ 演示试卷/知识点树”；`docs/代码地图.md:118`（§2 `demo_data.dart` 行）：“演示数据定义……（共 9 道，`demoQuestions()`）……`demoQuestions()` 目前没有生产调用方”。
- 现象：第五阶段 SR-P2-13 已把 `demoQuestions()` 整个函数删除，三处注记指向一个不存在的函数；按注记去找定义会找不到。时序：第四阶段先写了“仅作定义保留”，第五阶段删了函数，两阶段报告均未回头修正。
- 证据：`lib/data/demo_data.dart:3-8` 注释“SR-P2-13：`demoQuestions()` 已删除……留着是误导”；全仓 `grep demoQuestions lib/` 除该注释外 0 命中。
- 修的方向：三处改为“`demoQuestions()` 已于 Batch 5（SR-P2-13）删除；演示题的唯一合法来源是 v1 老库（已整体删除，不迁移）”；`demoExams()` / `demoKnowledgePoints()` 仍在 `_seed` 里用，保留的说法不变。
- 严重度：**P1**（文档与代码直接冲突）。

### SR2-10 — decision-log D-23 正文仍写“回退占位”与“落盘/渲染仍是待办”，与现行代码相反

- 位置：`docs/decision-log.md:225-226`（D-23）：“模型缺失、加载失败或图片文件不存在时回退占位（一页一个整题框），不抛错”；`:251-253`：“`detectPage` 按传入路径找文件，找得到跑真实推理，找不到回占位。真实文件落盘 / PDF 渲染仍是待办，见 YOLO 报告。”
- 现象：D-23 是现行 YOLO 接入的 operative 决定（D-07 已标注被它取代），其正文两处关键句仍是 2026-11-13 的旧口径。SR-P2-71 只修了 `YOLO-INTEGRATION-REPORT.md`，未修 D-23 本体。
- 证据：代码 `lib/services/yolo_onnx_service.dart`——失败返回空框 + `usedFallback: true`，不回占位框；`lib/services/import_service.dart:14,20,43-64` 导入已真实落盘到 `imports/<task-id>/`；`lib/services/pdf_render_service.dart` 已按页渲染。对照：`YOLO-INTEGRATION-REPORT.md` §2/§4/§8 已按同一口径改完，同一事实在两份文档里说法相反。
- 修的方向：D-23 两处改为与 YOLO 报告一致——“模型缺失/加载失败/文件不存在时返回空框 + `usedFallback: true`，不回占位框”；“导入已真实落盘（`imports/<task-id>/`），PDF 由 `pdf_render_service.dart` 按页渲染”；若 D-23 正文其余历史句仍有效，只改这两句。
- 严重度：**P1**。

### SR2-11 — P1-2 确认拆题只测成功路径，未测事务中途失败回滚

- 位置：`test/b5_p1_256_test.dart`（`SR-P1-2 确认拆题` 组，2 个用例）；`test/collect_page_test.dart`（保留任务同次提交断言）。
- 现象：SR-P1-2 的原 bug 是“保留任务重建在事务外，崩溃窗口丢任务 + 丢未框页草稿”。DB 层测试只断言一次成功调用同时建出拆分题 + 拆分任务 + 保留任务 + 未框页草稿（含旋转角）；收集页测试只断言保留任务与拆题是同一次 `confirmSplit` 调用提交。没有任何用例在事务中途注入失败——若事务实现退化为多步写库（或某一步静默吞错），测试仍全绿。
- 证据：同批的 P1-3 与 P1-4 都用了 `BEFORE UPDATE/INSERT` 触发器做失败注入并断言整体回滚；P1-2 组内无触发器、无 `throwsA`。
- 修的方向：在 `confirmSplitInto` 的后半段写操作上立触发器（如 `BEFORE INSERT ON question_boxes` 抛错），断言：调用抛错，且 questions / collect_tasks / question_boxes / 保留任务均保持调用前状态，原任务行仍在。
- 严重度：**P1**（测试缺口；被保护的恰恰是 P1-2 的核心修法）。

### SR2-12 — SR-P2-60 导入任务 id 只断言两次 id 不同，未断言 6 位随机段格式

- 位置：`test/b5_p2_services_test.dart`（`SR-P2-60 任务 id 加随机段` 组第 1 个用例）。
- 现象：用例只做两次顺序 `enqueue` 并断言 `first.first.id != second.first.id`。每次 `enqueue` 都含文件复制 + 解码，耗时远超 1ms，两次调用几乎必然落在不同毫秒——旧的“毫秒 + 序号”方案同样能通过，钉不住“同一毫秒两次导入不撞 id”这一回归点。实现是 `task-<毫秒>-<序号>-<6 位随机>`（`lib/services/import_service.dart:198`）；用例未对格式做任何断言。
- 证据：同一修复的另一半（收集页确认拆题 id）在 `test/b5_p2_collect_test.dart`（SR-P2-22 成功确认用例）里用了正则 `^task-\d{13}-\d{6}-\d+-\d+$` 钉格式；导入侧没有对等断言。
- 修的方向：断言导入任务 id 匹配 `^task-\d+-\d+-\d{6}$`（或直接断言含 6 位随机段）；如能安排同一毫秒内两次调用，再断言 id 不同。
- 严重度：**P1**。

### SR2-13 — SR-P2-75 放大对话框只断言对话框还在，未断言缩放真的变了

- 位置：`test/b5_p2_services_test.dart`（`SR-P2-75：放大对话框点 ＋/－ 仍可用`）。
- 现象：用例点 ＋ 再点 －，最后只断言标题 `整题图 · 放大查看` 还在。原 bug 是“缩放因子在 build 里赋值”——带 bug 时点 ＋ 会触发重建、缩放被重置回初始值，但对话框本身不会消失，该用例带 bug 也能通过。对话框实际有可观测的缩放状态：`_ZoomDialogState` 用 `_scale` 渲染 `'${(_scale * 100).round()}%'` 徽标（`lib/widgets/widgets.dart:833` 起、`_onTransform` 更新徽标）。
- 证据：用例内无任何对 `%` 徽标、`_scale` 或 `TransformationController` 矩阵的读取。
- 修的方向：点 ＋ 前后读徽标文本，断言百分比变大；点 － 后断言变小（或读 `InteractiveViewer` 的 `TransformationController` 矩阵缩放分量）。
- 严重度：**P1**。

## P2（65 项）

### 数据层（SR2-14～SR2-19）

#### SR2-14 — 全行 REPLACE 快照写覆盖库内新值：`setReviewJoinedInto` 会把 `review_count` 打回旧值

- 位置：`lib/data/db_questions.dart:29-33`（`setReviewJoinedIntoImpl`，`_toRow(q.copyWith(reviewJoined: joined))` + `ConflictAlgorithm.replace`）；同款：`lib/data/db_questions.dart:144-148` 经 `repository.dart:saveRemedy` → `upsertCauseRecord`（整行 REPLACE）；`lib/data/repository.dart:toggleFavorite/archive/save` → `upsertQuestionIntoImpl`（`db_questions.dart:177-183`，同款 REPLACE）。
- 现象：`review_count` 是库内唯一用 SQL `+1` 递增的字段（`db_questions.dart:155`），内存里的 `Question` 对象不感知它。一次自查把库内 `review_count` 从 5 加到 6 后，任何一路拿着旧快照（`reviewCount: 5`）的全行 REPLACE 都会把它打回 5。`setReviewJoinedInto` 是 B5 新包进事务的写路径（SR-P2-8），事务化修了“题行 + 错因记录不同步”，但没修“整行覆盖”——旧快照问题原样进了新事务版。同理：`saveRemedy` 的 `upsertCauseRecord` 会用旧快照覆盖并发自查改掉的 `status`/`solvedCount`/`recheckDate`（复习页内是串行流程，实际难触发；跨页/跨会话的旧 `Question` 对象经 `toggleFavorite`/`archive`/`save` 走同一 REPLACE 路径则可达）。
- 证据：数据组探针 P-C（内存库实测）：题 `review_count=5` → `recordSelfCheckInto(result: 'solved')` 后库内为 6 → 持 `reviewCount: 5` 的旧快照调 `setReviewJoinedInto(db, stale, true)` → 库内变回 5。
- 修的方向：状态类写操作按列 UPDATE 而不是整行 REPLACE（`setReviewJoined` 只改 `review_joined` 列；`toggleFavorite`/`archive` 同理）；`saveRemedy` 只改 `remedy_history` 列；或写前重读库内行再合并。`review_count` 本身只应由 SQL `+1` 改，任何 `_toRow` 整行写都不应带它。
- 严重度：**P2**（`reviewCount` 目前无页面渲染，用户侧暂不可见；但属于静默写坏已存数据，且一旦将来渲染题级复习次数即暴露。非 B5 引入，复审发现）。

#### SR2-15 — `upsertFolder` 整科同名把关非原子：并发写入可绕过，库里出现两个同名文件夹

- 位置：`lib/data/db_catalog.dart:465-482`（先 `await folderNameExistsInSubjectFrom` 判重，再 `insert ... ConflictAlgorithm.replace`，两步都在事务外）；`folders` 表无 `UNIQUE(subject_id, name)` 约束（`db_schema.dart:126-129`）。
- 现象：B5 称 `upsertFolder` 是“最后一道防线”，但判重与写入之间有 await 间隙，两路并发同名写入可同时通过判重、先后插入成功。单用户单进程 UI 下正常操作是串行的，实际触发需两处入口同时写（如组织页与详情页各新建同名文件夹、或测试/后台任务并发），概率低；但“防线”本身不是防线——它防不住它声称要防的情况。
- 证据：数据组探针 P-D（`Future.wait` 同时调两次 `upsertFolder`，同科同名 `试卷`，id `f-a`/`f-b` → 库里同名行 2 行）。
- 修的方向：判重 + 插入包进同一 `db.transaction`；或给 `folders` 加 `UNIQUE(subject_id, name)`（需先处理旧库已存在的重名行；新库从空开始，可直接改 DDL；或插入改 `ConflictAlgorithm.fail` + 捕获后转“已经有了”）。
- 严重度：**P2**（触发概率低；与 SR-P2-36 的“把关”宣称不符）。

#### SR2-16 — SR-P2-4 校验仍放过空字符串主键：`id: ''` 的备份可恢复入库

- 位置：`lib/data/db_backup.dart:137-147`（`_validateBackupRow`：TEXT 主键只查 `row['id'] is! String`；`settings` 的 `key` 同款 `:138`；必填列 `:152-164` 只查 null 与类型）。
- 现象：`''` 是合法 `String`，通过全部校验；SQLite 的 TEXT PRIMARY KEY 允许空串，恢复后库里出现 `id: ''` 的学科/题/文件夹（`_iconFor('')` 等下游按空 id 走，未必立刻报错，但属于脏数据）。同理必填 String 列（`name` 等）为空串也放行。B5 的 P2-4 修法只堵了“缺键 / null / 类型错”，未堵“空串”。
- 证据：数据组探针 P-E（`subjects: [{id: '', name: '数学', color: 1}]` 的备份 JSON 调 `validateBackupData`，应抛错而实际通过）。
- 修的方向：TEXT 主键与必填 String 列要求 `isNotEmpty`（`id`/`key`/`name`/`title`/`subject_id` 等）；空串即按“损坏的备份”拒绝。
- 严重度：**P2**（需恶意或损坏的备份才触发；校验缺口本身是 P2-4 的宣称范围）。

#### SR2-17 — `readZip` 不拒重名条目：同名条目两次进位，第二次 rename 失败被误报成“文件写不进去”

- 位置：`lib/services/zip_archive.dart:202-252`（`readZip`，中央目录逐项校验条目数/偏移/名/方法/尺寸，但不检查重名）；`lib/data/db_backup.dart:437-457`（进位循环：同名条目的 staging 文件第二遍写入覆盖第一遍，第一遍已 `rename` 走，第二遍 `staged.rename(dest.path)` 因源文件不存在抛 `FileSystemException`）→ `:470-476` 的 catch 把它归为“恢复失败：文件写不进去，原题库没动”。
- 现象：重名 zip 是结构损坏的备份，应报“备份已损坏”；实际报磁盘问题，用户会被误导去查磁盘空间。数据本身不丢（失败时 `movedIn`/`backedUp` 回滚已跑，库未动——`importBackupJsonInto` 在进位之后才调），只是文案与定性错误。`backup.json` 重名是例外：恢复取最后一个，进位循环又跳过它，不触发本问题。
- 修的方向：`readZip` 内按名判重，重名即抛 `ZipFormatException`；或恢复入口在写 staging 前校验条目名唯一。
- 严重度：**P2**（仅文案误导 + 损坏备份定性错误，无数据丢失；`buildZip` 不产重名包，需手工构造或第三方工具才触发）。

#### SR2-18 — SR-P2-10 防呆口径不一致：`confirmSplitInto` 的框回填仍用 REPLACE 且不去重

- 位置：`lib/data/db_collect.dart:396-412`（题的框逐行 `txn.insert(... ConflictAlgorithm.replace)`，无去重）；对照：同函数题/拆分任务已改先查 + `fail`（`:381-412`），保留任务草稿有 `seenIds` 去重（`:515-518`）。
- 现象：同一题的 `boxesByQuestionId[q.id]` 里若有两个同 id 框（调用方构造失误或重复传入），后者静默覆盖前者，不报错——与 P2-10“重复确认显式失败而不是静默覆盖”的修法方向不一致。正常流程走不到（`collect_page.dart:592` 构造时每框 id 唯一，`normalizeBoxEditorInputs` 也去重），且框 id 碰撞概率在 SR-P2-12 熵加大后可忽略；残余的是“同一入参内重复 id”这一纯调用方失误口子。
- 修的方向：主路径复用保留任务的 `seenIds` 去重（重复 id 直接跳过或显式抛错）；或框插入改 `ConflictAlgorithm.fail`。
- 严重度：**P2**（低；正常流程不可达，属防呆口径未统一）。

#### SR2-19 — SR-P2-5 估算不含 staging 临时占用：估算放行、恢复仍可能因盘满中途失败

- 位置：`lib/data/db_backup.dart:389-410`（`estimatedBytes = usedBytes - replacedBytes + incomingBytes`，与 `_maxRestoreBytes` 比较）；`:424-457`（先把文件解到 `.restore-staging-<时间戳>` 再进位）。
- 现象：恢复峰值占用是 `usedBytes + incomingBytes`（staging 里的副本与原文件共存），而估算只算恢复后占用 `usedBytes - replacedBytes + incomingBytes`。例：现有 1.5GB、备份带 0.9GB 文件、其中 0.5GB 会覆盖旧文件 → 估算 1.9GB 放行，峰值 2.4GB；目标盘剩余空间不足时 staging 写一半失败，走回滚 + “恢复失败：文件写不进去”。数据不丢（回滚已验证），但一次估算口径说“能恢复”的备份实际恢复失败，且失败文案不提空间。
- 修的方向：估算改用峰值口径（`usedBytes + incomingBytes`，或至少在 staging 写之前按峰值再判一次剩余空间）；或 staging 写失败时文案区分“空间不足”。
- 严重度：**P2**（低；需接近 2GB 的库 + 所剩盘空间不足才触发；数据安全不受影响）。

### 收集 / 整理 / 详情（SR2-20～SR2-27）

#### SR2-20 — 重框“恢复自动框”只认第一道题级框，`reworkQuestionId` 的比较永假

- 位置：`lib/modules/collect/box_editor.dart:703-711`（`_restoreAutoBoxForRework`）。
- 现象：`final target = layer1.firstWhere((b) => targetId == null || b.id == targetId, orElse: () => layer1.first)`，其中 `targetId = widget.reworkQuestionId`，详情页传的是题 id（`question_detail_page.dart:330` 的 `reworkQuestionId: q.id`），永不等于框 id。于是单框题靠 `orElse` 兜底恰好正确，多框题（重框允许一题多个 1 层框）永远只对第一道框做 IoU 匹配与替换、只跟随其内框；若检测框实际对应的是第二道框，IoU 对第一道框算出来 ≤0.05，还会误报“没找到对应的题，请手动框选”，或把第一道框挪到第二道题的位置上、与第二道框重叠导致确认被重叠校验拦下。
- 证据：代码走读；B5 的 P2-20 测试只用单 1 层框（`initialBoxesByPage: {2: [_box(id: 'q1-box', ...)]}`），`reworkQuestionId: 'q1'` 与框 id 的死比较被单框掩盖。
- 修的方向：按题意逐个目标框做 IoU 匹配替换（或在重框入口限制一题一框并写明）；测试补多框用例：两道 1 层框 + 各挂内框，恢复后两道框各就其位、内框各自跟随。
- 严重度：**P2**（单框题不受影响；多框题是允许态）。

#### SR2-21 — “恢复自动框”的手动判断查了全部页，当前页无手画框也会误弹确认

- 位置：`lib/modules/collect/box_editor.dart:650-658`（`_restoreAutoBoxes`）。
- 现象：B5 修 SR-P2-19 时把 `hasManual` 从“只查 1 层框”扩到 `_inners.values.any(hasManualIn) || _standaloneInner.values.any(hasManualIn)`，但 `_inners` / `_standaloneInner` 是跨页的 map，`_boxes` 却只是当前页。当前页只有 YOLO 框、别页有手画框时，点“恢复自动框”也会弹“用自动框替换当前页的手动框？”，而确认后 `_ingestDetected` 只替换当前页——对话框的文案与实际行为不符，属于误弹。
- 证据：代码走读；B5 的 P2-19 测试只覆盖“当页手画独立框弹确认 / 纯 YOLO 页不弹”，未覆盖“手画框在别页”的对照。
- 修的方向：`hasManual` 只查当前页：`_boxes` + `_inners` 中 `'$page:'` 前缀的键 + `_standaloneInner[page]`。
- 严重度：**P2**（只多一次确认弹窗，不丢数据）。

#### SR2-22 — `_hasSplitSibling` 是派生信号而非持久化信号，删拆分任务行后保留任务的警告消失

- 位置：`lib/modules/collect/collect_page.dart:117-125`（字段注释称“补信号”）、`:145-160`（`_load` 内由现存拆分任务行派生）、`:1147-1152`（`_taskRow` 的 `warnUnboxed`）。
- 现象：B5 称 `_hasSplitSibling` 是“持久化信号”，实际每次 `_load` 由当前任务表重新派生，没有任何字段落盘。保留任务（P1-2 重建回 needBox、未框页无草稿）之所以警告，全靠同源拆分任务行还活着。用户在收集页删掉全部同源拆分任务行（待整理行上的“删除”允许删，见 `_deleteTask`），下次 `_load` 该信号即消失，保留任务不再警告——它确实打开并确认过，警告本应继续。
- 证据：代码走读；`_hasSplitSibling` 无任何写盘路径（全仓 grep 无写操作，只有 `_load` 内赋值）。B5 的 P2-25 测试只覆盖新导入/修框中/有草稿三任务，未覆盖“拆分兄弟被删”的保留任务。
- 修的方向：任务行加持久化“已打开过修框”标志（`_openBoxEditor` 置 boxing 时已落盘，可直接用状态；保留任务重建时把该标志带上），或删拆分任务时不同步影响保留任务的警告判断。
- 严重度：**P2**（只影响一行警告文案的显隐，不影响流程）。

#### SR2-23 — `allCauses` 不去重，旧数据同名自定义仍在详情页与错题本重复显示

- 位置：`lib/models/models.dart:345`（`List<String> get allCauses => [...errorTypes, ...customErrorTypes]`）。
- 现象：B5 的 P2-27 只堵了新入口（新建自定义拦同名）与整理/详情编辑时的读入+保存合并；未重保存过的旧题，库里仍有固定名自定义。详情页信息区 `q.allCauses.join('、')`（`question_detail_page.dart:1272-1274`）会显示“其他、其他”；错题本紧凑行 `_causeStatusesOf`（`wrongbook_page.dart:434`，无记录时按 `allCauses` 逐条出 pill）同样重复；详情复习记录区按 `allCauses` 逐条出行的几处（`:1039-1040`、`:1636`、`:1766`）亦然。报告 Top5 不受影响（按题 id 集合计数），`syncCauseRecords` 内部用 `toSet` 去重亦不受影响——纯显示重复。
- 证据：代码走读；`allCauses` 全仓 20+ 处消费，均直接读库对象，不经过整理/详情的合并逻辑（协调员已复核确认 getter 本体）。
- 修的方向：在 `allCauses` getter 内保序去重（`{...errorTypes, ...customErrorTypes}.toList()`），一处修、全链路受益；或入库时迁移旧数据。
- 严重度：**P2**（仅旧数据显示重复；新数据已无法产生）。

#### SR2-24 — `realRegionRects` 跨父框比切片面积，获胜内框可能不属于切片来源的框

- 位置：`lib/widgets/widgets.dart:84-118`（`realRegionRects`）。
- 现象：B5 的 P2-24 b 方案“面积最大者胜”比较的是换算后（切片坐标 0..1）的面积；不同父框下的内框在切片坐标系下面积不可比——小父框下的小内框换算后可能比大父框下的大内框“更大”。更关键的是切片归属：题的切片只按首个 1 层框裁出（确认拆题每题取其第一个 1 层框裁剪），而 `realRegionRects` 对每个内框按其各自 `parentBoxId` 换算、再跨父框取胜；获胜内框若挂在非首个父框下，画在首个框的切片上位置是错的。
- 证据：代码走读；`layer2BoxToSliceRect(parent ?? firstLayer1, b)` 的换算基准是各自父框，`out[b.type]` 的胜负比较不带父框信息。
- 修的方向：只取切片来源父框（首个 1 层框）下的内框参与比较，或按页图坐标面积比较；测试补“两父框同区域内框，胜者应为切片来源父框下的那一个”。
- 严重度：**P2**（仅多 1 层框的题会触发；单框题不受影响）。

#### SR2-25 — `_confirmSplit` 成功后 `saveRecentTask` 在 try 外，失败时拆题已提交但无反馈、列表不刷新

- 位置：`lib/modules/collect/collect_page.dart:687-695`（`_confirmSplit` 尾部）。
- 现象：`confirmSplit` 事务成功后，`await widget.repo.saveRecentTask(...)` 无任何 try；写库失败时异常抛到 `_openBoxEditor`（同样无 try），进而成为未处理的异步异常：成功提示不弹、尾部的 `_load()` 不执行，列表停留在拆题前的旧态（任务仍显示待框选），用户须手动切页/重进才刷新。拆题本身已提交，无数据丢失。
- 证据：代码走读；与 SR-P1-4 同类“事务后收尾写库无保护”，只是影响面小（仅最近任务记录 + 列表刷新）。
- 修的方向：收尾包 try/catch，失败记日志或忽略，不影响“已生成 N 道题”的成功提示与 `_load()`。
- 严重度：**P2**。

#### SR2-26 — `_openQueue` / `_goTo` / `_jumpToQuestion` / `_applyQueueSort` 的 `_saveCurrent` 无 try，保存失败时队列打不开且无提示

- 位置：`lib/modules/organize/organize_page.dart:372-376`（`_openQueue`）、`:326-332`（`_goTo`）、`:438-450`（`_jumpToQuestion`）、`:456-463`（`_applyQueueSort`）。
- 现象：B5 的 P1-7 把 `_openQueue` 改成异步并在弹层前 `await _saveCurrent()`，但保存失败时异常直接逃出 `onTap`（`InkWell.onTap` 是 `void Function()?`，异步异常无人接）：队列打不开、没有任何提示。修前同步版至少能打开队列。`_goTo` / `_jumpToQuestion` / `_applyQueueSort` 同款。
- 证据：代码走读；四处均无 try/catch，`_saveCurrent` 内 `repo.save` 与 `syncCauseRecords` 均可抛错。
- 修的方向：保存包 try，失败弹提示后仍允许打开队列/切题（表单改动留在内存里，用户可重试保存），或明确拦下并提示原因。
- 严重度：**P2**（仅写库失败时触发；但 P1-7 的修法把“保存失败 = 队列打不开”变成了新行为）。

#### SR2-27 — `boxesForPageImageFromImpl` 仍无 `ORDER BY`，P2-24 的 a 方案未落实

- 位置：`lib/data/db_collect.dart:221-237`（`boxesForPageImageFromImpl`，两次 `db.query` 均无 `orderBy`）；对照 `:199`（`boxesForTask` 有 `orderBy: 'page ASC, id ASC'`）。
- 现象：B5-P2-COLLECT §7 转交数据层工人的第 1 项，至今未落实。`realRegionRects` 的“同面积取第一个”依赖输入列表顺序，而输入顺序即库返回行序（无 ORDER BY 时通常是 rowid 序，但 SQLite 不保证）。B5 的 b 方案（面积最大优先）已实现，面积不等时已确定；面积相等时仍不确定。
- 证据：代码走读；全仓 `orderBy` 检索：`db_collect.dart` 仅 `:10` 与 `:199` 两处有，`boxesForPageImageFromImpl` 不在其中。
- 修的方向：按转交项补 `ORDER BY page ASC, id ASC`（与 `boxesForTask` 对齐）。
- 严重度：**P2**（仅同区域同面积的并列情况受影响；实践中 rowid 序稳定）。

### 错题本 / 复习 / 报告 / 首页（SR2-28～SR2-34）

#### SR2-28 — 目录拖拽调序时文件夹搜索开着会移错位置：缝隙下标按过滤后的可见列表算，`_reorderFolder` 却按全量列表解释

- 位置：`lib/modules/wrongbook/wrongbook_directory.dart:12-16, 56-61`（顶层缝隙按 `visibleTops` 建，`visibleTops` 是搜索过滤后的子集）、`:317-320`（子文件夹缝隙按 `kw` 过滤后的 `kids` 建）→ `lib/modules/wrongbook/wrongbook_page.dart` `_reorderFolder`（`siblings` 取全量 `_topFolders(subjectId)` / `_subFolders(parentId)`，`fromIndex`/`toIndex` 都按全量算；SR-P2-42 的 `idx > fromIndex` 减 1 修正也建立在“同一张表”前提上）。
- 现象：搜文件夹时拖拽，缝隙下标与全量下标错位，落点与所见不符。例：顶层 A、B、C、D，搜到 B、D（可见 `[B, D]`）；把 D 拖到 B 与 D 之间的缝隙（过滤视图里的 gap 1，用户预期不动）→ `_reorderFolder` 得 `toIndex=1`、`fromIndex=3`（全量），`1 > 3` 不成立不减 1，插到 1 得 `[A, D, B, C]`——D 跳到了 B 前面。子文件夹同理。
- 证据：代码链即证据；B5 的 SR-P2-42 测试只在无搜索时拖拽，未覆盖搜索态。
- 修的方向：二选一：(a) 搜索有关键词时禁用缝隙拖拽（`_buildGapTarget` 的 `onWillAcceptWithDetails` 在 `kw.isNotEmpty` 时返回 false）；(b) 把可见下标换算成全量下标再调 `_reorderFolder`。修后加一测：搜索过滤后拖拽，顺序与所见一致（或缝隙拒收）。
- 严重度：**P2**。

#### SR2-29 — 学习报告学科分布仍把已掌握题算进去，与封面/目录/列表的“扣已掌握”口径不一致

- 位置：`lib/modules/report/report_page.dart:171-176`（`_questionsInRange` 只滤 `isOrganized && !q.isArchived`）、`:423-429`（分布行 `qsIn.where(subject).length`）vs `lib/modules/wrongbook/wrongbook_shelf.dart:168-176`（封面总数扣 `_isMastered`）、`lib/modules/wrongbook/wrongbook_directory.dart:217-224`（“全部题目”行扣已掌握）、`lib/modules/wrongbook/wrongbook_page.dart:370-379`（`_folderCount` 扣已掌握）、`:551-560`（`_filteredAll` 默认藏已掌握）。
- 现象：同一科同一时段，报告“数学 · N 道错题”会大于错题本封面总数与目录总数，差额正好是该范围内已掌握的题数——正是 SR-P1-11 当初投诉的症状（“报告分布数会大于错题本题数”），只不过 B5 修掉了未整理/已归档两个来源，留下了已掌握这个来源。弱点 Top5 两处（`_causeGroups` 跳过已解决记录、`_kpGroups` 跳过全解决的题）已经不含已掌握题，分布是唯一还含的口径。
- 证据：`_distRow` 的计数源 `qsIn` 与 `_causeGroups`/`_kpGroups` 是同一份，但后两者各自另有“已解决排除”逻辑，分布没有；B5-P1-10-11.md 称分布“与错题本 `_filteredAll` / `_folderCount` 的收录口径一致”，与代码不符——`_filteredAll` 默认视图与 `_folderCount` 都扣已掌握。
- 修的方向：**需 Meng 裁决**：(a) 分布也扣已掌握（与封面/目录同口径，分布数 = 该科封面总数）；(b) 维持分布按历史错题数（含已掌握），把该口径写进报告页头注释，并修正 B5-P1-10-11.md 里“口径一致”的说法。注意 (a) 会改变“错在哪个学科”的语义：已掌握的科会显示 0 道，需要他确认。
- 严重度：**P2**。

#### SR2-30 — SR-P2-50 修得不完整：`insideCacheDir` 是死参，目录按 1 个计，预览个数仍偏小

- 位置：`lib/modules/settings/settings_page.dart:555-600`（`_scanCacheSync` 的 `walk`/`add`）；预览文案 `:1140`（`'临时文件 ${preview.tempCount} 个、缩略图缓存 ${preview.thumbCount} 张，共约 ${preview.mb} MB'`）。
- 现象：(1) `insideCacheDir` 从未为 true：`walk` 递归进普通子目录时原样透传（`walk(e, insideCacheDir: insideCacheDir)`），而遇到名字含 cache/thumb/tmp 的目录时是 `add()` 后 `continue`，从不以 `insideCacheDir: true` 递归进去。于是 `else if (insideCacheDir) add(e, 'temp')` 分支不可达，是死代码。(2) 目录按 1 个计：`add()` 对目录只 `tempCount++/thumbCount++` 一次、字节数递归累加，目录里的文件不逐个计数。纯 Dart 探针（把 `walk`/`add` 原样复制到独立脚本，夹具树：`work/thumb-cache/a.png + b.png`、`work/deep/x.tmp`、`work/cache/f1~f3.txt`、`work/sub/inner-cache/z.bin + y.bin`，每文件 10 字节）实测：`temp=3 thumb=1 bytes=80 items=4`——8 个文件只算出 4 项（thumb-cache 2 张图算 1 张、cache 目录 3 个文件算 1 个、inner-cache 2 个文件算 1 个），字节数是对的（80），个数是错的。B5 报告“深层也被发现并计数”只在“项被发现、能清理”层面成立（`items` 里确实有这些目录，`_clearCache` 会递归删掉），不在“个数”层面成立；预览文案说的是“X 个/张”，用户看到的个数仍偏小。(3) 验证缺口未补上：B5 报告明说该 widget 测试“已写，未跑通”，本次审查同样没能跑 `test/settings_page_test.dart`（clang 丢失，`flutter test` 无法构建）。该测试至今无一次 live widget 运行记录。
- 证据：探针输出与代码链（`settings_page.dart:574-600`）一致；`grep insideCacheDir` 全项目只有定义处与透传处，无一处传 `true`。
- 修的方向：二选一：(a) 让 `walk` 对 cache/thumb/tmp 目录也递归进入（`insideCacheDir: true`），目录里的文件逐个按类计数，目录本身不再单独计 1（避免重复计）；(b) 维持目录按项计，改预览文案为“X 项”并删掉死参。无论选哪种，修后要在机器空闲时单跑 `flutter test test/settings_page_test.dart` 把 SR-P2-50 测试真正跑通一次。
- 严重度：**P2**。

#### SR2-31 — SR-P2-51 金角轮转的生成色与既有色 hue 只差 2°～7°，第 13/14/16/17 科肉眼近乎撞色

- 位置：`lib/modules/subjects/subjects_page.dart:307-324`（`orElse`：`hue = (usedColors.length * 137.5) % 360`，撞色避让只在 `usedColors.contains(candidate)` 精确相等时步进 37°）；色表 `:36-53`（12 色）。
- 现象：金角序列从 `n = usedColors.length = 12` 起算，而不是从 0 起算的经典分散序列，生成 hue 恰好落在既有色旁边。实测 hue：`第 13 科（n=12）：210.0°，距数学蓝 216.6° 仅 6.6°；第 14 科（n=13）：347.5°，距玫红 349.7° 仅 2.2°；第 16 科（n=15）：40.0°，距琥珀 37.7° 仅 2.3°；第 17 科（n=16）：177.5°，距青绿 173.4° 仅 4.1°。`饱和度/明度也被固定为 0.65/0.85，与既有色的 0.59～1.00/0.66～0.99 同档，区分度主要只剩 hue——2° 的 hue 差在圆点/标题色上基本看不出。`while` 循环只防精确 `Color` 相等，防不住近色。
- 证据：上述 hue 均为实算；既有测试（`test/subjects_page_test.dart:654`，13 科“色全不同”）只断言精确不等，近色照样通过。
- 修的方向：生成色与全部已用色算 hue 距离（环形），小于阈值（协调员建议 25°）时继续步进金角/37° 直到拉开；或把 12 色表扩到 16 色以上再轮转。阈值与做法由 Meng 定（见“需 Meng 裁决的新项”）。
- 严重度：**P2**（裁决 (a) 的附带缺陷，见“裁决复核”）。

#### SR2-32 — SR-P2-37 首字母排序修得不彻底：同首字母按 Unicode 码点排（不是拼音），未映射汉字回退为原字、排在所有已映射字母之后

- 位置：`lib/modules/wrongbook/wrongbook_page.dart:163-180`（`_subjectInitial`、`_subjectKeyCompare`）。
- 现象：(1) 平局比较用学科名全串 `compareTo`（Unicode 码点序）：同首字母 S 的“数学”与“生物”，码点上 数（U+6570）< 生（U+751F），排“数学”在前；按拼音应是 sheng（生物）< shu（数学），“生物”在前。排序结果与下拉文案“学科首字母 A → Z”不符。(2) 未映射汉字回退为该字本身（`:171` 的 `?? first`）：与已映射的拉丁字母比较时，汉字码点（U+4E00+）恒大于拉丁字母，未映射学科一律排在所有已映射学科之后，且两个未映射学科之间仍按码点排、不是拼音。(3) 空名回退 `''`，排在最前面（`''` 小于一切），未知学科反而置顶。
- 证据：代码链即证据；B5 的两项测试（`test/wrongbook_page_test.dart:1568/1581`）只用化学/数学/物理/英语/政治五个已映射学科，未覆盖平局与未映射。
- 修的方向：平局比较改按“首字母 + 全名拼音”排（或至少用映射表把全名逐字转首字母串再比）；未映射汉字给一个确定性的回退（仍用原字比较、但注释写明不是拼音序），或扩映射表覆盖常见学科首字；空名回退到 `'{'`（排最后）或与未知学科同档处理。
- 严重度：**P2**。

#### SR2-33 — 按组“开始解决”进会话时，范围文案仍写筛选口径，实际只治该组一个错因

- 位置：`lib/modules/review/review_page.dart:476-517`（`_startSession`：`fromGroup != null` 时 `blocks = _buildBlocks(_filtered, onlyCause: fromGroup?.cause)`，但 `scopeLabel` 一律取 `_scopeLabelForFilters()`，不看 `fromGroup`）。
- 现象：无任何筛选时，点某组（如数学“计算错误”）的“开始解决”，会话只含该组错因（SR-P2-49 决定 (b)，`_buildBlocks` 的 `onlyCause` 正确），但会话元信息行（`:1566`，`'第 ${_bi + 1} / ${_blocks.length} 道题 · $_scopeLabel'`）却显示“全部待解决错因”；有学科筛选时则显示“数学这一科”，同样夸大了范围（只治其中一个错因）。用户按文案理解会以为本轮治完该科/全部，实际只治了一个错因。SR-P2-57 修的是断点恢复条与 `_scopeLabelForBlocks`，这个新建会话入口的文案没同步。
- 证据：代码链即证据；B5 的 SR-P2-49 测试（`test/review_page_test.dart:939`）走的是错因筛选 + 顶栏“开始解决”，文案恰好吻合，没覆盖按组入口的文案；“按组开始解决”测试（`:702`）只断言块数，不看文案。
- 修的方向：`fromGroup != null` 时 `scopeLabel` 用该组写，如 `'${学科名} · ${错因}'`（与 `_scopeLabelForBlocks` 的单科单错因分支同款）；修后在“按组开始解决”测试里加文案断言。
- 严重度：**P2**。

#### SR2-34 — 复习错因筛选与错题本错误类型筛选的下拉也没有旧值兜底，详情页删题回来可能断言

- 位置：`lib/modules/review/review_page.dart:1037-1050`（错因下拉 `value: _causeFilter`，选项来自 `_allCauses`）；`lib/modules/wrongbook/wrongbook_list.dart:238-246` 附近（错误类型下拉 `value: _filterErrorType`，选项 = 固定错因 + `_questions` 里全部题的 `allCauses`）；`_causeFilter`/`_filterErrorType` 在 `_load` 里从不校验。
- 现象：同一页生命周期内（详情页是压在上面的路由，原页 State 活着，回来后调 `_load`），筛选值指向的错因可能已消失：复习页筛“计算错误”→ 进会话 → 在详情页归档/删除唯一带该错因的题 → 暂停回列表 → `_allCauses` 里已无“计算错误”，`_causeFilter` 仍是它 → DropdownButton 断言（归档会把题移出 `_groups`/`_curedGroups`；治愈不会触发，因为已解决组仍进 `_allCauses`）。错题本：筛选面板开着、错误类型筛了 X → 在详情页删除唯一带 X 的题 → 回来 `_load` 后选项里无 X，`_filterErrorType` 仍是 X → 同样断言（归档不触发，因为 `_questions` 是 `includeArchived: true` 全量；只有删除触发）。页面切换会重建 State（`lib/app.dart` `_buildPage` 按路由新建页面，无 IndexedStack 保活），所以跨页删除不构成此问题，只有上述“详情页删题/归档后回本页”路径构成。
- 证据：代码链即证据；`grep` 确认 `_causeFilter`/`_filterErrorType` 在 `_load` 与各导航方法里均无复位/校验（`_clearFilters` 只在换科/换文件夹/重置时调，不在详情返回时调）。
- 修的方向：与批量条同款防线：在 `_load` 的 `setState` 里（或下拉 `value` 处就地）校验——值不在当前选项里时回落到 `'全部'`/null；或在 build 里用就地计算的 `effectiveValue`（不写回状态）。修后加一测：筛某错因 → 删掉唯一带该错因的题 → 回列表不断言、筛选回到“全部”。
- 严重度：**P2**（与 SR-P0-2 / SR2-7 同类第三处）。

### 服务层 / 主题 / 组件（SR2-35～SR2-38）

#### SR2-35 — SR-P2-64 的修法把 `QmChip` 双区芯片的可点面积缩成了文字本身，内边距与两区之间的间隙点按无反应（Batch 5 新回归）

- 位置：`lib/widgets/uikit.dart:625-675`（`QmChip` 双区分支，`_QmPressable(childHandlesTap: true)` + 内层两个 `GestureDetector`）。
- 现象：双区芯片（`onTap != null && onDelete != null`）现在只有标签文字与 `×` 字形本身能点；芯片的水平内边距（`deletableChipPaddingH = 12`）、垂直内边距（`deletableChipPaddingV = 4`）以及标签与 `×` 之间的 4px 间隙（`SizedBox(width: 4 * scale)`）点按后什么都不发生。更糟的是按压视觉仍会闪一下：外层 `_QmPressable` 的 `Listener`（`:243-252`，`childHandlesTap` 时驱动 `_pressed`）对全芯片的 pointer down 都有反应，用户看到芯片按下去了、却没有任何操作。
- 证据：服务组临时探针（已删）：点芯片左内边距（`rect.left + 3`）`tapped=0 deleted=0`；点标签与 `×` 之间的间隙中点 `tapped=0 deleted=0`；对照点标签文字 `tapped=1 deleted=0`；对照点 `×` `tapped=1 deleted=1`。结构原因：内层两个 `GestureDetector` 只包 `labelText(fg)` 与 `QmGlyph(close)` 两个子 widget（`:651-675`），`Container` 的 padding 与中间的 `SizedBox` 不在任何一个识别器内；外层 `_QmPressable` 在 `childHandlesTap` 时 `_tapEnabled` 为假（`:189`），不装 Tap 识别器。修前外层 `_QmPressable` 的 `GestureDetector(behavior: HitTestBehavior.opaque)` 覆盖整个芯片，点哪里都有效。B5 的 P2-64 测试只点了标签文字中心与 `×` 字形中心，死区因此漏网。
- 修的方向：把点按热区恢复到整个芯片，同时不恢复内外双识别器竞争。二选一：(a) 标签区的 `GestureDetector` 包住含左内边距的区域（padding 移进标签识别器内，`×` 识别器热区向外扩到右内边距），间隙归属标签区；或 (b) 外层 `_QmPressable` 保留一个“只在点按落点不在内层识别器内时才生效”的兜底（落点判断走 hit test，不进手势竞技场）。修后补测：点内边距与间隙的探针用例（本次探针的两个点位可直接转正为回归测试）。
- 严重度：**P2**（点文字仍可用，但芯片是小目标，用户自然点按位置大量落在内边距上；且“按下无反应 + 有按压闪烁”比纯死区更误导）。

#### SR2-36 — SR-P2-66 的雾化漏了第三个入口：`subjectLabelColor` 在深色下仍直接返回库里存的饱和色

- 位置：`lib/widgets/widgets.dart:727-750`（`subjectLabelColor`），`return stored;` 在 `:737`。
- 现象：Batch 5 只雾化了 `DesignTokens.subjectColor` / `subjectInk`（`design_tokens.dart:349,381` 走 `_darkStoredMist`），但 `widgets.dart` 里另有一份独立的学科色入口 `subjectLabelColor`，对非预设学科、有 `stored` 时不分亮深直接 `return stored`。深色下新学科在这些位置仍是饱和亮色——正是 SR-P2-66 原文描述的缺陷本身。
- 证据：代码（`:732-738`：`if (stored != null && subjectId != 'math' && …) { return stored; }`，其后才判断 `dark`；其文档注释也仍写着旧口径）；调用点（全部在深色可见位置）：`:311` `QuestionSlice` 加载失败占位 34px 学科图标；`:374` `_missingImagePlaceholder` 同款图标；`:617` `CompactSliceThumb` 失败占位 14px 图标；`:763` `SubjectLabel` 的 8px 圆点 + 学科名文字（文字色也是存色原值）。探针（已删）：深色主题下 `SubjectLabel(subjectId: 'chemistry', color: #2E7CF6)` 的圆点色实测等于存色原值 `#2E7CF6`，而雾化值应为 `#7CAAF2`（`Color.lerp(#2E7CF6, #DCE3EC, 0.45)`）。B5 的 SR-P2-66 测试只断言了 `DesignTokens.subjectColor/subjectInk`，没有覆盖 `subjectLabelColor`，所以漏网。
- 修的方向：`subjectLabelColor` 的深色分支改走与 `subjectColor` 同一雾化（最好直接委托 `DesignTokens.subjectColor/subjectInk`，不要再造第三份“存色深色怎么处理”的规则）；同步改掉它头顶的文档注释。顺带：`lib/modules/subjects/subjects_page.dart:43` 的注释“亮/深两主题都直接用存色画圆点”也已过期（该页圆点实际走 `DesignTokens.subjectColor`，深色已雾化），一并改掉——注释，不影响行为。
- 严重度：**P2**（与原 SR-P2-66 同级；只影响新学科、只在深色、只在占位图标与 `SubjectLabel` 位置；但它是“已修完”项的直接残留）。

#### SR2-37 — SR-P2-69 的 Codec 泄漏在修框编辑器里仍活着：`_loadPageImageSize` 从不 dispose `Codec`

- 位置：`lib/modules/collect/box_editor.dart:421-444`（`_loadPageImageSize`；`instantiateImageCodec` 在 `:425`）。
- 现象：该函数 `await ui.instantiateImageCodec(bytes)` 后只 `dispose()` 了解出的 `frame.image`，`codec` 本身在成功路径与异常路径上都未释放。每次切页都调一次（`initState` 与切页时重调），修框翻页越多漏得越多。Batch 5 的 SR-P2-69 只修了 `page_image_pipeline.dart` 的 `_decode` / `canDecodeImageBytes` 与 `yolo_onnx_service.dart` 的 `detectPage`，本处是全仓库第 4 个 `instantiateImageCodec` 调用点（`grep` 全仓库仅 4 处），是唯一漏网的。
- 证据：代码即证据——该函数体内无任何 `codec.dispose()`；对照已修的两处（`page_image_pipeline.dart:212-218` 的 `try/finally`、`yolo_onnx_service.dart:155-161` 的 `try/finally`）。
- 修的方向：与已修两处同款 `try/finally` 里 `codec.dispose()`（先取帧、再释放；`getNextFrame` 抛错时 `finally` 同样释放）。
- 严重度：**P2**（与原 SR-P2-69 同级；单次泄漏小，但修框是高频翻页操作）。

#### SR2-38 — `clampToPage` 仍保留 SR-P2-70 的旧钳制模式，B5 报告“与 clampToPage 同一语义”的说法不成立

- 位置：`lib/services/yolo_onnx_service.dart:571` 起（`clampToPage`）；对照 `lib/services/page_image_pipeline.dart:60-75`（`rotateBoxToRotatedPage`，已修为区间求交）。
- 现象：`rotateBoxToRotatedPage` 已修（`x=-0.1, w=0.5 → x=0, w=0.4`），但 `clampToPage` 的实现仍是“先钳左上角、宽只收到剩余空间”：`x = box.x.clamp(0,1)`，`maxW = 1 - x`，`w = box.w.clamp(0, maxW)`。输入 `x=-0.1, w=0.5` 时输出仍是 `x=0, w=0.5`——框整体右移且未缩宽，与 SR-P2-70 原文描述的缺陷逐字相同。B5 报告（`B5-P2-SERVICES.md` SR-P2-70 节）称新实现“与 `YoloOnnxService.clampToPage(minSize: false)` 同一语义”，实测不成立：同一输入，两函数输出的 `w` 分别是 0.4 与 0.5。
- 证据：既有测试把旧行为钉死了：`test/yolo_onnx_service_test.dart:81-88` 用例名“负坐标：左上角收到 0，尺寸不变”，断言 `box(-0.2, -0.1, 0.5, 0.5)` 钳制后 `w` 仍为 `0.5`。影响面不只理论：检测管线 `_toPageBox`（`minSize: false`）与修框编辑器检测结果入库（`box_editor.dart:500`，`clampToPage(b, minSize: false)`）都走它；YOLO 框贴到页左/上边缘、letterbox 换算出轻微负坐标时，框会被整体平移且右/下沿超出真实检测框，溢出量有多大、框就偏多大。但注意：`clampToPage` 默认 `minSize: true` 的分支（编辑器手画/拖动用）保留尺寸是有意的交互语义（框被拖出页边时不静默缩小、保持可抓取），其文档注释与测试用例是一致的——所以这不是无脑改成求交就能了事的项。
- 修的方向（协调员定）：(a) 只给检测路径（`minSize: false`）改成交集语义，编辑器路径保持现状，并把 `test/yolo_onnx_service_test.dart:81` 的用例按 `minSize` 分两组重写（`minSize: false` 时左溢出扣宽，默认时尺寸不变）；或 (b) 维持 `clampToPage` 现状，但把 B5 报告与 `page_image_pipeline.dart:63` 的“同一语义”注释改掉，写明两者有意不同。无论选哪条，`rotateBoxToRotatedPage` 本身不用再动。协调员选 (a)。
- 严重度：**P2**（触发需框贴左/上边缘溢出，YOLO 输出多在页内，概率低；但报告说法错误会误导后续接手者按“同一语义”去复用）。

### 文档（SR2-39～SR2-50）

#### SR2-39 — 边界 §4.2“已整理完成的任务仍留在列表中”：`done` 状态在现行流程中到不了，读者看到的已整理任务显示为“待整理”

- 位置：`docs/quiz-master2-mo-kuai-bian-jie-hua-fen.md` §4.2（Batch 5 第四阶段 SR-P1-24 所改）：“已整理完成的任务仍留在列表中（可删除），不自动归档、不隐藏”。
- 现象：该句按字面理解为“整理完的任务以‘已整理’状态留在列表”。实际上没有任何生产代码会把任务置为 `done`；整理完成后任务仍是 `pendingOrganize`，行上显示“待整理”。文档的状态标签与界面实际标签对不上。
- 证据：代码 `lib/modules/collect/collect_page.dart:135-139` 注释“SR-P2-33：`CollectStatus.done` 全仓无赋值处——没有任何生产代码会把任务置为 `done`（已整理任务仍以 `pendingOrganize` 呈现）；这里的 `done` 分支是防御性保留”；`grep CollectStatus.done lib/` 只有解析（`db_codec.dart:181` 读回旧库字符串）与防御分支（`collect_page.dart:1284,1315,1390`），无赋值。反向核实：`_tasks = tasks` 不过滤（`:177`），`done` 行若从旧库读回确实会显示并可删除——所以该句对“旧库残留行”成立，对现行流程产生的任务不成立。
- 修的方向：改为“修框确认后（待整理状态）的任务一直留在列表中（含已整理进错题本的题对应的任务，行上仍显示‘待整理’，可删除）；`done` 状态仅作旧库防御保留，现行流程不产生”。原正确表述（SR-P1-24 修前）是“已整理完成的任务归档，不再出现在列表中”，该句本身是错的，不要恢复。
- 严重度：**P2**。

#### SR2-40 — 边界 §4.4 同一节内“不设序号”与“左上角蓝色序号圆盘”直接矛盾，口径未定

- 位置：`docs/quiz-master2-mo-kuai-bian-jie-hua-fen.md:136`（§4.4 大卡片）：“卡片上只有整题切片图与左上角蓝色序号圆盘”；`:144`（§4.4“不管什么”）：“不显示试卷来源、不显示复习次数、不显示收集时间、不设序号”。
- 现象：同一节既肯定大卡片有序号圆盘，又在“不管什么”里说“不设序号”。B5-DOCS-BOUNDARY 遗留 10 与 B5-DOCS 遗留、B5-P2-DOCS 遗留 2、B5-P2.md 遗留均只记为“观察，未改”。
- 证据：代码 `lib/modules/wrongbook/wrongbook_list.dart:706` 注释“序号 = 本页内的位置（1, 2, 3…），随排序 / 筛选 / 分页重编号”；`:740-779` `_buildLargeCard` 确有左上角蓝色序号圆盘；紧凑列表行（`:815-828`）无序号。两种可能口径均未在文档里定：(a)“不设序号”指紧凑列表行不设行号，大卡片圆盘是页内位置号，不算“序号”；(b)“不设序号”是旧句残留，应删。
- 修的方向：**需 Meng 裁决**——定 (a) 还是 (b) 后统一两处表述；若定 (a)，在 :144 句后加括号注“（指紧凑列表行不设行号；大卡片左上角页内位置圆盘保留）”。
- 严重度：**P2**。

#### SR2-41 — CODEBUDDY 与四方分工仍写“第五批修复进行中”，Batch 5 已全部完成

- 位置：`docs/CODEBUDDY.md:44`：“最终自审已做完（见 `docs/ui-replication/SELF-REVIEW-SUMMARY.md`，第五批修复进行中）”；`docs/四方分工.md:8-9`（基线行）：“第五批修复进行中，通过数会随修复推进变化”；`:60`（眼前第一步）：“最终自审已做完，第五批修复进行中；Meng 在自审汇总后决定是否推送代码”。
- 现象：Batch 5 五阶段已全部完成（B5-SUMMARY，测试 778/778），“进行中”已是过期状态描述；四方分工基线行的“最新数以 B5-SUMMARY 为准”注记本身真实存在且已生效，问题仅在“进行中”三字。
- 修的方向：三处“第五批修复进行中”改为“第五批修复已完成（2026-11-15，测试 778/778，未推代码；下一步第二次自审 → Meng 决定是否推送）”；基线行的 628/628 快照本身带日期与“以 B5-SUMMARY 为准”注记，可保留。
- 严重度：**P2**。

#### SR2-42 — 代码地图头注仍只写到 Batch 4，未提 Batch 5

- 位置：`docs/代码地图.md:6-15`（头注）：“本文 2026-11-14 按第三批修复（Batch 3）后的代码重写过关键小节……第四批 God 类拆分（Batch 4）后的文件结构见第 2、3、6 节。仓库里仍有 Batch 1/2/3/4 未提交的改动……最终验证已跑——B3 与 B4 均已由协调员跑过最终统一验证：`flutter analyze` 0 问题、全量测试 628/628 通过（Batch 4 结束时）”。
- 现象：SR-P1-38 的修复（头注称“最终验证还没跑”）本身已落实，但头注的“最新验证”仍停在 Batch 4；Batch 5 的改动（P0–P2、测试 778/778）未在头注留位置，读者按头注会以为 628/628 是最新数。
- 修的方向：头注补一句“Batch 5（最终自审 134 项修复）已完成、未提交未推；最终验证：analyze 0 问题、全量测试 778/778、Linux Release 构建成功，结论见 `B5-SUMMARY.md`”；并把“仍有 Batch 1/2/3/4 未提交的改动”改为“Batch 1/2/3/4/5”。
- 严重度：**P2**。

#### SR2-43 — 代码地图里 Batch 5 新增的共享函数与新测试文件没有位置

- 位置：`docs/代码地图.md` §2 文件表（`lib/data/repository.dart` 行 :117 只写“各页面共用的业务查询口径”）、§3 数据流、`test/` 说明（:152 只写“测试文件，每个模块基本都有一个 `*_test.dart`”）。
- 现象：Batch 5 新增的跨页共享入口在代码地图里查不到：`ReviewBucket` / `reviewBucketOf()` / `isReviewDue()`（`lib/data/repository.dart:18-43`；首页、错题本封面、今日待办三处共用的互斥拆分，SR-P1-1 的核心改动）；`normalizeBoxEditorInputs()`（`lib/modules/collect/box_editor.dart:120`；SR-P1-5/6 的 Layer-2 归一化单函数）；`normalizeWrongbookSort()` / `wrongbookSortValues`（`lib/models/models.dart:593-607`；SR-P0-2 的排序值归一）；`_hasSplitSibling` 信号（`lib/modules/collect/collect_page.dart:125,132,181,1151`；SR-P2-25 的保留任务识别信号）；新测试文件 `test/b5_p0_1_orphan_test.dart`、`test/b5_p1_1_subject_counts_test.dart`、`test/b5_p1_256_test.dart`、`test/b5_p2_data_test.dart`、`test/b5_p2_collect_test.dart`、`test/b5_p2_services_test.dart`、`test/import_service_p1_fixes_test.dart`（`test/` 目录实测已存在，代码地图只字未提）。
- 修的方向：在 §2 `repository.dart` 行补 `ReviewBucket` 三件套一句话；在 §4 收集中心/错题本小节或 §2 `box_editor.dart` / `models.dart` 行补归一化函数与排序归一各一句话；`test/` 说明补 B5 回归测试文件清单（或注明“Batch 5 回归测试见 `test/b5_*.dart`”）。
- 严重度：**P2**。

#### SR2-44 — B5-DOCS.md 与 B5-SUMMARY.md 的第四阶段范围串漏了 SR-P1-25、SR-P1-26

- 位置：`docs/ui-replication/B5-DOCS.md:4`：“范围：最终自审文档 P1 22 项（SR-P1-18～SR-P1-24、SR-P1-27～SR-P1-39）”；`docs/ui-replication/B5-SUMMARY.md:15`（阶段表第四行）：“SR-P1-18～24、P1-27～32、P1-33～39”。
- 现象：两处范围串的并集是 18–24（7 项）+ 27–39（13 项）= 20 项，漏了 SR-P1-25、SR-P1-26，却都称 22 项。工作本身没有漏修——`B5-DOCS-BOUNDARY.md` 范围行明确含“SR-P1-25、SR-P1-26”，正文亦有 §4.4 两条改动；错的是汇总层面的范围串。
- 修的方向：两处范围串补上“SR-P1-25、SR-P1-26”（或直接写“SR-P1-18～SR-P1-39”）。
- 严重度：**P2**。

#### SR2-45 — B5-P1-COUNTS.md 标题“6 项”与正文 7 项不符

- 位置：`docs/ui-replication/B5-P1-COUNTS.md:4`：“范围：最终自审 P1 口径类 6 项（SR-P1-1、SR-P1-9、SR-P1-10、SR-P1-11、SR-P1-12、SR-P1-13、SR-P1-15）”。
- 现象：括号里列了 7 个编号（P1-1、9、10、11、12、13、15），标题却写 6 项；正文亦按 7 项分节（SR-P1-1、SR-P1-10+11、SR-P1-9+13+12、SR-P1-15），测试算术 661 + 13 = 674（4+2+5+2）与 7 项一致。
- 修的方向：标题“6 项”改为“7 项”。
- 严重度：**P2**。

#### SR2-46 — B5-P2-COLLECT.md 与 B5-P2.md 的收集组计数错误，SR-P2-22 被两组重复计入

- 位置：`docs/ui-replication/B5-P2-COLLECT.md:5-6`：“原任务 18 项（SR-P2-18、19、20、21、23、24、25、26、27、28、29、30、31、32、33、34、35；SR-P2-22 不属原任务）+ 补充转交 4 项……结论：22 项全部完成”；`docs/ui-replication/B5-P2.md:26`：“收集/整理/详情（原 18 项 + 转交 4 项，全部完成）”。
- 现象：括号里列出的原任务编号实际只有 17 个（18、19、20、21 共 4 个；23、24、25 共 3 个；26–35 共 10 个），不是 18 项；17 + 4 = 21，不是 22。另 SR-P2-22 同时出现在数据层工人范围（B5-P2-DATA“P2-1～17、22（部分）”）与收集组转交（“SR-P2-22 剩余部分”）里，两组计数都含它，汇总时未说明是同一项分两半。
- 修的方向：原任务改为“17 项”，结论改为“21 项全部完成”（或把 P2-22 的拆分口径写清：数据层半项 + 收集组半项，合计仍算 1 项）；B5-P2.md 同步改。
- 严重度：**P2**。

#### SR2-47 — B5-P2.md 称“删 `CollectStatus.done` 死分支”，与工人报告及代码都矛盾

- 位置：`docs/ui-replication/B5-P2.md:27`（收集组摘要）：“……`_donePages` 文案说清；切页/取消保存加 try；`firstWhere` 兜底；删 `CollectStatus.done` 死分支与 `DashedDivider`/`InfoChip` 死代码……”。
- 现象：`done` 分支没有被删。工人报告原文是保留（`B5-P2-COLLECT.md` SR-P2-33 行：“`done` 分支保留作防御，并在 `_load` 的 `splitPagesBySource` 处加了说明注释。无行为可测”）；代码里 `done` 分支仍在（`lib/modules/collect/collect_page.dart:1284` 行文案、`:1315` 状态 pill、`:1390` 删除按钮，另 `:135-139` 防御注释）。
- 修的方向：B5-P2.md 该句改为“`CollectStatus.done` 分支保留作防御（旧库读回时仍显示；现行流程不产生 `done`，见 SR-P2-33）；删 `DashedDivider`/`InfoChip` 死代码”。
- 严重度：**P2**。

#### SR2-48 — B5-SUMMARY 与 B5-P2 的遗留“报告页月筛选口径仍为 `age <= 30`”指错了页面

- 位置：`docs/ui-replication/B5-SUMMARY.md:52`（遗留·需 Meng 裁决）：“报告页月筛选口径仍为 `age <= 30`（自审未定）”；`docs/ui-replication/B5-P2.md:63`（遗留）：“需 Meng 裁决：报告页月筛选口径仍为 `age <= 30`（自审未定，错题本工人未动）”。
- 现象：`age <= 30` 的月口径不在报告页，在错题本列表的时间筛选；报告页的“本月”是自然月（当月 1 日起），两处口径本就不同，遗留把待裁决项安到了错误的页面，会误导 Meng 去裁决一个不存在的问题。
- 证据：代码：错题本 `lib/modules/wrongbook/wrongbook_page.dart:574-584`——`limit = week ? 7 : 30`，月分支 `age <= limit`（即 31 天含今天），筛选项“最近一月”（`wrongbook_list.dart:278`）；报告页 `lib/modules/report/report_page.dart:111-113`——`'month' => DateTime(now.year, now.month, 1)`，全文无 `age`、无 `30`。正确出处：`B5-P2-WRONGBOOK.md:20` SR-P2-45 行写的是“月筛选 `age <= 30` 未动”，上下文是错题本组，本身没错；错的是汇总到 B5-SUMMARY/B5-P2 时前面加了“报告页”。
- 修的方向：两处遗留改为“错题本列表‘最近一月’筛选口径仍为 `age <= 30`（31 天含今天，自审未定；报告页‘本月’是自然月 1 日起，两处口径本来就不同，是否统一需另定）”。真正的待裁决项见“需 Meng 裁决的新项”第 3 条。
- 严重度：**P2**。

#### SR2-49 — SELF-REVIEW.md SR-P2-81 的证据句“`reviewCount` 仍保留显示”失实

- 位置：`docs/ui-replication/SELF-REVIEW.md:663`（SR-P2-81）：“……复习次数（`reviewCount`）仍保留显示。证据：`lib/modules/detail/question_detail_page.dart:17`；`:1587-1611`（每错因‘下次复查 …’）”。
- 现象：`reviewCount` 只存模型与库，从未在任何页面渲染；所引的两处证据只能证明“每错因下次复查日”存在，证明不了题级复习次数有显示。B5-P2-DOCS 已正确偏离自审字面方向（只写每错因解决次数与下次复查日，未写“复习次数”），处理正确；失实的是 SELF-REVIEW 原文。
- 证据：`grep -rn "\.reviewCount\|reviewCount:" lib/`——仅模型字段、编解码、`question_detail_page.dart:268`（`_saveEdit` 时原值透传，不渲染）；边界 §4.6 现写“复习记录（各错因状态、解决次数、下次复查日与全部解决记录）”与代码一致，无“复习次数”。
- 修的方向：SELF-REVIEW.md 是已冻结的审阅记录，不宜改写正文；在本报告与 B5-P2-DOCS 遗留 1 处留档即可，并提醒 GPT 一次性复审不要以该句为准。题级复习次数是否应显示，仍是 B5-SUMMARY 遗留的另立产品改动（`reviewCount` 只存不用）。
- 严重度：**P2**。

#### SR2-50 — B5-P2.md 的测试净增数 104 与各组新增数之和 108 对不上，差额未具名

- 位置：`docs/ui-replication/B5-P2.md:56`（阶段统一验证）：“全量测试：**778/778 通过**（基线 674，净增 104；新测试文件 `b5_p2_data_test` 36、`b5_p2_collect_test` 27、`b5_p2_services_test` 14，另有错题本/复习/首页/学科管理/设置各文件新增；个别旧测试随行为变更删除/合并，计数口径以全量为准）”；同文件 :30：“新增回归测试 31 项”（错题本组）。
- 现象：36 + 27 + 14 + 31 = 108，与净增 104 差 4。报告只用“个别旧测试随行为变更删除/合并”一笔带过，未写明删/并的是哪 4 项（或哪几处），从报告本身无法复算。
- 修的方向：在该句后补被删/合并的测试清单（如“删除 X 测试 2 项、合并 Y 测试 2 项，见 B5-P2-WRONGBOOK.md §x”）；若实为 31 项中有 4 项是改写既有测试而非新增，改为“新增 27 项 + 改写 4 项”。
- 严重度：**P2**。

### 测试质量（SR2-51～SR2-78）

#### SR2-51 — SR-P2-21 只测了“点空白退出”，未测“点框上不退出”

- 位置：`test/b5_p2_collect_test.dart`（`SR-P2-21` 组，用例名含“点框上不退出”）。
- 现象：用例只在画布中心（空白处）点了一次左键并断言退出内框模式；从未在框上点按。用例名后半句“点框上不退出”无对应操作与断言——若修复过度（点哪都退出，含框上拖动起点），测试仍全绿。
- 修的方向：在进入内框模式后先点一次框体，断言仍在内框模式，再点空白处断言退出。
- 严重度：**P2**。

#### SR2-52 — SR-P2-44 只设了搜索文本，未设任何筛选

- 位置：`test/wrongbook_page_test.dart`（`SR-P2-44 换科/换文件夹时搜索与筛选清零`）。
- 现象：用例换科前只在搜索框输入了 `函数极限`；`_clearFilters()`（`lib/modules/wrongbook/wrongbook_page.dart:670`）实际清的是搜索 + 7 个筛选字段（试卷、错因类型、时间范围、错因状态、错因名、收藏、逾期）+ 标签/知识点 + 页码/勾选。筛选字段的清零完全没有用例覆盖，用例名“搜索与筛选清零”只兑现了一半。
- 修的方向：换科前先设一个筛选（如错因类型或时间范围），换科后断言该筛选回到默认值（如下拉显示“全部”）。
- 严重度：**P2**。

#### SR2-53 — SR-P2-40 只测逗号，未测竖线

- 位置：`test/wrongbook_page_test.dart`（`SR-P2-40 批量加标签：含逗号的新标签拦下，不入库不保存`）。
- 现象：实现禁令是“不能含逗号**或竖线**”（`lib/modules/wrongbook/wrongbook_page.dart:1163`），用例只输入了 `新标,签`；`|` 分支无用例。
- 修的方向：补一个输入 `新标|签` 的用例，断言同样拦截、不入库、不保存。
- 严重度：**P2**。

#### SR2-54 — SR-P2-59 只测放行侧，未测新估算的拒绝侧

- 位置：`test/b5_p2_services_test.dart`（`SR-P2-59` 组）。
- 现象：用例用稀疏文件把占用顶到 2GB−5MB，2MB 的 PDF 放行进 `needBox`，钉住了“旧算法误拒、新算法放行”。但新算法的拒绝边界没有任何用例：占用 2GB−1MB 时 2MB 的 PDF 应被拒，若估算公式写错导致超限仍放行，测试发现不了；全仓亦无其他用例覆盖导入存储估算的拒绝路径。
- 修的方向：补占用 2GB−1MB + 2MB PDF 的用例，断言任务失败且错误含存储上限提示。
- 严重度：**P2**。

#### SR2-55 — SR-P2-66 期望色用与实现相同的公式算出，只用一个输入色

- 位置：`test/b5_p2_services_test.dart`（`SR-P2-66：新学科存色深色下雾化……`）。
- 现象：实现是 `_darkStoredMist = Color.lerp(stored, 0xFFDCE3EC, 0.45)`（`lib/theme/design_tokens.dart:365`），用例期望值同样写 `Color.lerp(stored, const Color(0xFFDCE3EC), 0.45)`。因常量是字面写在用例里的，改常量仍会失败（不属于严格的“改实现不改测试也能过”），但期望值不是独立字面量，且只用了一个输入色 `0xFF2E7CF6`。
- 修的方向：期望值改写为算好的字面色值，并补第二个输入色（如一饱和暖色）断言雾化结果。
- 严重度：**P2**。

#### SR2-56 — SR-P2-51 第 13 科的金角生成色只断言“不相同且不是数学蓝”

- 位置：`test/subjects_page_test.dart`（`SR-P2-51 第 8 科起仍有新色……`）。
- 现象：第 8 科（青绿 `0xFF14B8A6`）、第 9 科（草绿 `0xFF84CC16`）都断言了字面色；第 13 科（金角生成）只断言 13 色互不相同且不是数学蓝。金角步进算错仍能通过（只要颜色互不相同）。另：该用例未断言生成色与既有色的 hue 距离，SR2-31 的近色（347.5° vs 玫红 349.7°）照样通过。
- 修的方向：断言第 13 科颜色的字面值，并补生成色与全部已用色的 hue 距离断言（阈值见 SR2-31）。
- 严重度：**P2**。

#### SR2-57 — SR-P2-11 Windows 文件锁定防线在 Linux 上未被直接测到

- 位置：`test/b5_p2_data_test.dart`（`SR-P2-11 删老库先清附属` 组）。
- 现象：用例对 `-wal` 是目录的情形只锁定了“只读探针打不开即拒绝删除、文件保留”，并在注释中说明“附属删失败不抛错的分支是防 Windows 文件锁定的防御代码，Linux 单测无法直接模拟”。即 SR-P2-11 的核心修复分支（附属删失败时不抛错、继续删主库）在 Linux 测试里没有可执行的覆盖，只留了注释。
- 修的方向：无 Linux 侧直接修法时，记为 Win11 真机手动核查项（删老库时模拟文件被占用）；若后续把删除逻辑抽象出可注入的文件操作层，再补单测。
- 严重度：**P2**。

#### SR2-58 — SR-P2-5 2GB 边界恰好等于上限的情形未测

- 位置：`test/b5_p2_data_test.dart`（`SR-P2-5 备份恢复 2GB 上限` 组）。
- 现象：拒绝侧用 2GB+1 字节（稀疏文件），放行侧用 1GB；恰好 2GB 时是拒是放（`>` 还是 `>=`）没有用例。
- 修的方向：补占用恰为 2GB 的用例，断言与实现口径一致的行为。
- 严重度：**P2**。

#### SR2-59 — SR-P2-2 用例名与断言矛盾（名说“不动”，断言是“被改写”）

- 位置：`test/b5_p2_data_test.dart`（`SR-P2-2 清演示数据走删题事务` 组，`演示题的框清掉、任务指向置空；recent_tasks 与复习断点不动`）。
- 现象：用例名说“复习断点不动”，实际断言 `review_state.queue == '[]'`——含演示题的断点队列被改写（演示条目被清掉），行还在、内容变了。断言本身正确，名字误导。
- 修的方向：改名，如“演示题的框清掉、任务指向置空；断点队列去掉演示条目、其余不动”。
- 严重度：**P2**。

#### SR2-60 — P1-4 未测 `_failAndClean` 本身也失败的分支

- 位置：`test/import_service_p1_fixes_test.dart`（`SR-P1-4` 组）。
- 现象：文件头注释写明修复含“`_failAndClean` 再失败也只返回内存里的 failed 任务”；用例的触发器只让“写 needBox 的 UPDATE”失败，`_failAndClean` 的 failed 写库仍能成功。第二层失败路径无用例（与 SR2-2 的产品缺口对应）。
- 修的方向：补触发器让全部 `collect_tasks` 写操作失败的用例，断言 `enqueue` 不抛、仍返回 2 个内存 failed 任务。
- 严重度：**P2**。

#### SR2-61 — P1-1 首页焦点卡用例用手填的 FakeRepo 数据，未覆盖真实仓储到首页的接线

- 位置：`test/b5_p1_1_subject_counts_test.dart`（`首页焦点卡拆分与封面三数一致` widget 用例）。
- 现象：该用例把 `due`/`rev` 手填进 `FakeRepo` 再断言焦点卡文案，钉的是渲染；封面三数与首页数的互斥拆分一致性由同文件的仓储层单测钉住。真实仓储 → 首页这一段接线没有 widget 用例。属合理分层、轻微缺口。
- 修的方向：如需补，写一个用真实 `QuestionRepository`（内存库 + 种子题与错因记录）泵首页的用例，断言焦点卡文案；或明确记为分层测试的已知边界。
- 严重度：**P2**。

#### SR2-62 — SR-P2-22 成功确认用例未跑“两次确认撞同一毫秒”的真实碰撞场景

- 位置：`test/b5_p2_collect_test.dart`（`成功确认：拆出的题与拆分任务 id 带 6 位随机段（SR-P2-60 同款）`）。
- 现象：用例断言一次确认内两题的随机段相同、id 符合 `^import-\d{13}-\d{6}-\d+-\d+$` 格式；注释自认“两次确认的随机段大概率不同（格式即防线）”。格式正则能拦住回退到“毫秒+序号”旧格式，但两次确认落在同一毫秒时 id 是否仍不同，未被实际跑过。
- 修的方向：同一用例内连续确认两次（如两个单页任务），断言两次的随机段不同；或在 id 生成层对“同一毫秒连续调用”做确定性单测。
- 严重度：**P2**。

#### SR2-63 — SR-P2-74 只测 dpr=3.0，无 dpr=1.0 对照

- 位置：`test/b5_p2_services_test.dart`（`SR-P2-74：cacheWidth 乘 devicePixelRatio`）。
- 现象：只在 `devicePixelRatio: 3.0` 下断言 384 / 960 两个字面值；dpr=1.0 时的基准值（128 / 320）无对照，`cacheWidth` 与 dpr 的乘法关系只在一个点上被钉住。另：封顶值 2048 / 384 未被触发（`CompactSliceThumb` 在 dpr 3.0 时 384 恰好等于封顶，属巧合而非封顶测试）。
- 修的方向：补 dpr=1.0 的对照断言，并补 dpr 4.0+ 用例断言 `QuestionSlice` 封顶 2048、`CompactSliceThumb` 封顶 384。
- 严重度：**P2**。

#### SR2-64 — P1-1 未测复查日恰好是今天的边界

- 位置：`test/b5_p1_1_subject_counts_test.dart`（`reviewBucketOf` 与场景用例）。
- 现象：场景只用“昨天到期”与“7 天后到期”；`isReviewDue` 对 `recheckDate == 今天` 是否算到期，没有用例。复查日当天是“待复查”还是“已解决”的分界点。
- 修的方向：在 `reviewBucketOf`/`isReviewDue` 用例中补 `recheckDate` 为今天（零点与当前时刻各一）的情形。
- 严重度：**P2**。

#### SR2-65 — SR-P2-5 的 zip 用例均无文件条目，`incomingBytes`/`replacedBytes`/2GB 边界零覆盖

- 位置：`test/b5_p2_data_test.dart`，SR-P2-5 组——`'现有占用超 2GB 时拒绝整个恢复，原库不动'` 与 `'现有占用 1GB 时恢复放行（对照）'`。
- 现象：两个用例的 zip 都只有 `backup.json`、无任何文件条目，`incomingBytes` 与 `replacedBytes` 全程为 0。估算公式里“解压后总字节累加”“将被覆盖文件的抵扣”“恰好 2GB 边界（`>` 拒、`==` 放行）”三个分支零覆盖。SR2-19 的估算缺口正在这些分支里。
- 修的方向：zip 里放真实文件条目，覆盖 incoming 累加、replaced 抵扣、恰好 2GB 边界三分支（与 SR2-58 的边界用例可合并写）。
- 严重度：**P2**。

#### SR2-66 — SR-P2-6 零测试覆盖，B5 报告称“已测”与事实不符

- 位置：`test/b5_p2_data_test.dart`（SR-P2-6 无任何用例）；B5-P2-DATA.md 称“P2-6（staging 严格匹配 + DB 失败文案）”已测。
- 现象：`_isRestoreStagingDir` 的严格匹配（`.restore-staging-backup` 用户目录不动）与 zip 恢复三档文案（`BackupRestoreException` 原样抛 / `DatabaseException` →“备份数据有问题” / 其余 IO →“文件写不进去”）在全仓测试里零覆盖。`p3_backup_migration_test.dart` 只覆盖 zip 往返、路径穿越、缺 `backup.json`、版本过高四项。修法本身经代码核对是对的，但无回归保护。
- 修的方向：补三档文案与 staging 严格匹配的用例；修正 B5-P2-DATA.md“已测”的说法。
- 严重度：**P2**（B5 报告与事实不符，须纠正记录）。

#### SR2-67 — SR-P2-16 三分支无用例

- 位置：`test/b5_p2_data_test.dart`，SR-P2-16 组——只有 `'两次基于同一旧快照的“已解决”：计数 +2，不是 +1'` 与 `'复查通过不加计数：库内 solvedCount 不动，只顺延复查日'`。
- 现象：`'unsure' 不写库`（含“无行时返回传入值”分支）、`'未解决' solvedCount 清 0`、无行时按传入值写库三分支无用例。
- 修的方向：补三分支用例。
- 严重度：**P2**。

#### SR2-68 — SR-P2-15 `_`/`%` 转义分支无用例

- 位置：`test/b5_p2_data_test.dart`，SR-P2-15 组——`'拆分任务行还指着原目录：目录保留'` 与 `'无人引用：目录删掉（对照）'`。
- 现象：任务 id 均用无下划线的 `'orig'`，`_likeEscape` 的 `_`/`%` 转义分支无用例（生产任务 id 是 `task-<毫秒>-<序号>-<随机>`，不含 `_`，风险低）。
- 修的方向：补含 `_`/`%` 的任务 id 用例。
- 严重度：**P2**（风险低）。

#### SR2-69 — P0-1 旋转烘焙页图未覆盖

- 位置：`test/b5_p0_1_orphan_test.dart`——三用例覆盖 `pages/page-001.png`、`page-002.png` 与 `page-normalized.png`。
- 现象：未覆盖旋转烘焙页图 `pages/page-<p>-r<角度>.png`（与前者同属 `pages/` 枚举口径，风险低，但它是 P0-1 派生文件的另一类）。
- 修的方向：补旋转烘焙页图用例。
- 严重度：**P2**（风险低）。

#### SR2-70 — SR-P2-12 碰撞后 REPLACE 静默覆盖的行为本身无用例

- 位置：`test/b5_p2_data_test.dart`，SR-P2-12 组——`'随机段 16 位十六进制，1000 个不碰撞'` 只断言格式与 1000 个不碰撞。
- 现象：碰撞后 REPLACE 静默覆盖的行为本身无用例（与 SR2-18 同根；熵加大后概率可忽略）。
- 修的方向：补碰撞场景用例（或与 SR2-18 的去重修法一并处理）。
- 严重度：**P2**（概率可忽略）。

#### SR2-71 — P1-14 恰好 20MB 边界未测

- 位置：`test/import_service_p1_fixes_test.dart`，SR-P1-14 组（21MB 图片失败、20MB 以内对照、`oversizeHint` 文案）。
- 现象：无恰好 20MB（`size == limit`）的边界用例；代码用 `size > limit`，恰好 20MB 应放行，但没有任何测试钉住这条边界。PDF 50MB 边界同样未测。
- 修的方向：补一个恰好 20MB 的图片用例与一个恰好 50MB 的 PDF 用例。
- 严重度：**P2**。

#### SR2-72 — P1-17 同文件不同写法未测

- 位置：`test/import_service_p1_fixes_test.dart`，SR-P1-17 组（同路径两次 / 两不同文件 / 跨批）。
- 现象：只测同一路径字符串；同文件不同写法（大小写、符号链接、相对路径）未测。
- 修的方向：补同文件不同写法（大小写/符号链接/相对路径）的去重用例。
- 严重度：**P2**。

#### SR2-73 — P1-16 并发检测共用 `_loadFuture` 未测；无原生库时关键断言空跑

- 位置：`test/yolo_onnx_service_test.dart`，SR-P1-16 组（失败 → 恢复 → 缓存复用，三段式本身是好的负向测试）。
- 现象：缺口：并发检测共用 `_loadFuture` 未测；无 onnxruntime 原生库时 `markTestSkipped` 使关键断言空跑（环境依赖）。
- 修的方向：补并发检测用例；无原生库时至少断言跳过原因可观测（或在有原生库的环境跑通一次并记录）。
- 严重度：**P2**。

#### SR2-74 — SR-P2-37 同首字母平局 / 未映射汉字 / 空名未测

- 位置：`test/wrongbook_page_test.dart`，SR-P2-37 组（`:1568/:1581`）。
- 现象：只用五个已映射首字母的学科。未覆盖同首字母平局（数学/生物）、未映射汉字、空名（与 SR2-32 的产品缺口对应）。
- 修的方向：补平局、未映射、空名三组用例。
- 严重度：**P2**。

#### SR2-75 — SR-P2-47 未加入盒按学科分行顺序未测

- 位置：`test/review_page_test.dart`，SR-P2-47 组（`:905`）。
- 现象：只断言 13 道默认列 10 道、展开后全见。未覆盖未加入盒按学科分行的顺序（`ordered` 按 `_subjects` 顺序，未测新学科/未知学科排最后的分支）。
- 修的方向：补新学科/未知学科排最后的顺序用例。
- 严重度：**P2**。

#### SR2-76 — SR-P2-46 归档后 `_page` 越界回落与每页条数切换后页码复位未测

- 位置：`test/wrongbook_page_test.dart`，SR-P2-46 组（`:1765`）。
- 现象：只测 12 道两页、翻页。未覆盖归档后 `_page` 越界回落（第 2 页删到只剩 1 页时是否回到合法页）与每页条数切换后已归档页码的复位。
- 修的方向：补越界回落与页码复位用例。
- 严重度：**P2**。

#### SR2-77 — SR-P2-62 “UI 回调仍逐次”只断言 `length > 2`

- 位置：`test/b5_p2_services_test.dart`，SR-P2-62 组（“5MB 文件复制：进度 UPDATE ≤ 20 次，UI 回调仍逐次”）。
- 现象：写库节流一侧是真凭据（触发器计数 ≤20，实测 16），但“UI 回调仍逐次”一侧只断言了 `reported.length > 2` 与 `last == 100`——3 个值也能通过，钉不住“每 1% 都回调”。
- 修的方向：断言回调序列含 0→70 的连续百分比（或至少 `reported.length` 接近 70 + 渲染段）。
- 严重度：**P2**。

#### SR2-78 — SR-P2-68 ZIP64 / 多盘 / EOCD 带注释的拒绝路径无用例

- 位置：`test/b5_p2_services_test.dart`，SR-P2-68 组（5 项）。
- 现象：负向覆盖较好（数据描述符 stored+deflate、纯目录包、名不一致、超大单条目预判、空 zip），缺口是 ZIP64 / 多盘 / EOCD 带注释的拒绝路径无用例；旧备份兼容（`buildZip` 产包读回）在本组内无用例——但 `test/p3_backup_migration_test.dart` 有多处 `buildZip → readZip` 往返断言，缺口已被别组合上，不单独立项。
- 修的方向：补 ZIP64 / 多盘 / EOCD 带注释的拒绝用例。
- 严重度：**P2**。

## 三项协调员裁决的复核结论

### 裁决 (a) SR-P2-66 深色雾化：保留雾化做法——结论：成立，但修复不完整

- 雾化 45% 确实在代码里（`design_tokens.dart:365-366`：`_darkStoredMist` 为 `Color.lerp(stored, const Color(0xFFDCE3EC), 0.45)!`）；`subjectColor`（`:349`）与 `subjectInk`（`:381`）的非预设学科深色分支都走它；经 `subjectColor` / `subjectInk` / `subjectSoft` 的调用点全部受益（左导航圆点、学科管理行与圆点、首页学科卡、复习页学科名、错题本紧凑行学科名、`QmChip` 选中态填充）。预设三科不受影响。
- “15% 深底混色用在圆点/字色上会暗到看不清”属实：用 WCAG 相对亮度公式对深色底 `#262B33` 实算，12 色轮换色全部落在 **1.15–1.35:1** 之间（`#2E7CF6` 为 1.18:1）；雾化 45% 后全部 **5.75–8.56:1**，与预设三科深色雾色同一档（数学深色 `#87A9CC` 为 5.81:1），均超过正文 4.5:1 阈值。对照：存色原值 `#2E7CF6` 直接用在深底上对比度 3.61:1——看得见但低于正文阈值，雾化是改进而非多余。
- `subjectSoft` 深色分支确实未动（仍为 `Color.lerp(const Color(0xFF262B33), stored, 0.15)!`），且该用法合理：`subjectSoft` 只做底色 tint，文字走雾化后的 `subjectInk`，15% tint 做底色没有可读性问题；协调员“底色 tint 与圆点/字色是两回事”的区分成立。
- 唯一缺口是 SR2-36 的 `subjectLabelColor` 第三入口未雾化，补上即完整。另：`subjects_page.dart:43` 的注释“亮/深两主题都直接用存色画圆点”已过期，只影响注释。

### 裁决 (b) SR-P2-51 第 8 科颜色：扩到 12 色 + 金角轮转、不再回落数学蓝——结论：成立（字面），但附带 P2 级近色缺陷

- 12 色表完整（`lib/modules/subjects/subjects_page.dart:36-53`）：新蓝、新绿、新红、紫、橙、青、粉、青绿 `0xFF14B8A6`、草绿 `0xFF84CC16`、琥珀、靛蓝、玫红，共 12 个 distinct 值；第 8 科青绿、第 9 科草绿，与 B5 报告一致。
- 轮转逻辑正确（`:307-324`）：`firstWhere(未用色，orElse: 金角生成）`，12 色用完后不再回落 `_newSubjectColors.first`；撞色步进 37°、最多 12 次，有上界，不会死循环。
- 旧测试按新行为更新合理（`test/subjects_page_test.dart:654`）：连加 10 科共 13 科，断言 13 色全不同、第 13 科为金角生成色——与“不再回落第一色”的新行为一致，不是把旧期望硬改成新实现。
- 别的颜色回落点：新学科主色（`Subject.color`）无其他回落点。另有两处与学科色有关的回落，但不属于本项：`DesignTokens.subjectInk/subjectSoft` 对预设三科以外的学科无 `stored` 时回落数学色——那是“找不到学科/未传存色”的兜底，不是第 8 科起的回落；`CoverTokens.of` 未知 key 回落蓝色——那是封面底色系统（7 色 key），与学科主色无关。
- 缺陷（SR2-31）：金角起点取 `usedColors.length`（12 起），生成 hue 与既有色只差 2.2°～6.6°（第 13 科 210° vs 数学蓝 216.6°；第 14 科 347.5° vs 玫红 349.7°），`while` 只防精确相等。字面“不再回落数学蓝”成立，视觉可区分的目的未达成。

### 裁决 (c) SR-P2-52 / SR-P2-55：接受与自审字面相反的做法——结论：两项都成立

- **SR-P2-52（只乘字距、不乘字号）成立。** 自审原要求：学科名 `fontSize: 52` 与副标题 `fontSize: 16` 是固定值，要求“两处字号与字距同乘 `scale`”。工人实际做法：只把两处 `letterSpacing` 乘 `scale`（学科名 3.12、`错 题 本` 13.6，`lib/modules/wrongbook/wrongbook_shelf.dart:322, 351`），`fontSize` 不乘，并写明理由（D4 约定：字号由 `app.dart:267` 的 `MediaQuery TextScaler` 全局乘一次，`qmScaleOf` 取的就是同一因子；`letterSpacing` 不被 `TextScaler` 缩放）。理由成立的证据：D4 约定在 `lib/theme/design_tokens.dart` 六处一致表述；B5 报告的探针数据（1.3 倍下 52 → 67.6）与 Flutter 的 `TextScaler` 语义一致（只缩放 `fontSize`，不缩放 `letterSpacing`）。若按自审字面把 `fontSize` 也乘 `scale`，特大档会是 52 × 1.3 × 1.3 = 双重缩放，确实错。测试佐证：`test/wrongbook_page_test.dart:1811`（1.3 倍下“错 题 本”宽度 > 185，修复前 172、1.0 倍时 148）钉住了字距缩放的效果。附带观察（不另计问题）：字距乘 `scale` 后，大字号下学科名与副标题的总宽会超过标准档的书宽占比，B2 报告的 74.4px 纵向排布只在标准字号下实测过；三档字号下的封面排布仍建议 Meng 在 Win11 真机上顺手看一眼。
- **SR-P2-55（保留外层点按、去掉内层）成立。** 自审原要求：只留一处，建议留 `QmCoverMini.onTap`、删外层 `GestureDetector` 的 `onTap`。工人实际做法：相反——留外层 `GestureDetector(onTap: _setCover)` 为唯一处理，`QmCoverMini` 不传 `onTap`（`lib/modules/subjects/subjects_page.dart:733-760`，注释写明理由）。另一套真无害的证据：`QmCoverMini.build`（`lib/widgets/uikit.dart:941-945`）`onTap == null` 时直接返回装饰容器，不包 `_QmPressable`、不装任何手势识别器，与外层不存在手势竞争；外层 `GestureDetector` 包裹的是小图 + 下方样式名签整个格子，名签点按是既有交互（既有测试点 `find.text('圆点')` 触发选择），改只留内层会使名签点按失效——B5 报告称第一次尝试即因此失败 1 项，有测试证据。测试佐证：`test/subjects_page_test.dart:688`（点数学“圆点”小图 → `coverStyle` 变 `dots`，且 `saveSubject` 恰好调用 1 次）钉住了“单次保存”。附带观察（不另计问题）：改留外层后，点按失去了内层 `_QmPressable` 的按压态视觉反馈（外层是裸 `GestureDetector`，无涟漪/缩放）；功能正确，只是手感上轻微退化，如在意可给外层包一层按压态。

## 遗留项（本次核实结论）

- **报告页月筛选**：B5-SUMMARY 与 B5-P2 的遗留指错了页面——`age <= 30` 在错题本列表（`wrongbook_page.dart:581-592`，月分支 `age <= limit`，即 31 天含今天），报告页“本月”是自然月（当月 1 日起），两者是不同功能的各自口径。错题本改成 `age < 30`（30 天含今天）与周口径一致，改动只是一行；报告页自然月无需统一，但建议错题本筛选文案或注释写明是“最近 30 天”而非“本月”。是否改，需 Meng 裁决（见“需 Meng 裁决的新项”第 3 条）。
- **`reviewCount` 只存库、无页面渲染**：唯一写路径是 `recordSelfCheckIntoImpl` 内的 SQL `+1`（`db_questions.dart:155`）；模型/编解码/备份均携带；全仓无任何页面渲染（仅详情页 `:268` 原样带过）。但数字本身并非无处显示：详情页“复习记录”区的“解决次数”行显示 `_history.length`，正常流程里两者数值相等（同一事务既插 `review_history` 又 `+1`）。且其语义是**按错因计的自查次数**（一轮 3 个错因各查一次就 +3；复查通过也 +1），不是“复习轮次”，直接显示为“复习 N 次”会误导；是否显示、标什么需另立产品决定。另：它会被 SR2-14 的旧快照 REPLACE 打回（修 SR2-14 时一并解决写坏风险）。

## 需 Meng 裁决的新项（共 5 项）

1. **SR2-29**：学习报告学科分布是否扣已掌握——(a) 扣，与封面/目录同口径；(b) 维持历史口径，写进报告页头注释并修正 B5 说法。
2. **SR2-40**：边界 §4.4“不设序号”口径——(a) 指紧凑列表行不设行号，大卡片圆盘保留；(b) 删“不设序号”旧句。
3. **月筛选**：错题本“最近一月”是否从 `age <= 30`（31 天）改为 `age < 30`（30 天含今天，与周一致），并把文案写明“最近 30 天”；报告页自然月不统一（已确认不同功能）。
4. **`reviewCount` 是否显示、标什么**：按错因计的自查次数，显示为“复习 N 次”会误导；若显示，建议标为“自查 N 次”或只在详情页把“解决次数”行改成读该字段（与现文案等价，无新增信息）。
5. **三项协调员裁决请复核**：P2-66 雾化成立、但修复不完整（SR2-36 待补）；P2-51 字面成立、但金角近色（SR2-31，阈值建议 25°，由 Meng 定）；P2-52/55 成立。

## 建议修补顺序

1. 先修 P1 丢数据/回归类：SR2-3（重框切片，B5 新回归）→ SR2-1 → SR2-2（P1-4 两个残留口子，同一文件可一批修）→ SR2-4 → SR2-5 → SR2-6（整理队列两处快照）→ SR2-7（下拉断言，同类第三处 SR2-34 可一批修）→ SR2-11/12/13（P1 测试缺口，随对应代码修法一起补）。
2. 再修 P1 文档类：SR2-8 → SR2-9 → SR2-10（纯文档改动，可与代码批并行）。
3. 再修 P2 数据层：SR2-14（REPLACE 快照，牵连 reviewCount）→ SR2-15 → SR2-16 → SR2-17 → SR2-18 → SR2-19。
4. 再修 P2 收集/错题本/服务：SR2-20 → SR2-21 → SR2-22 → SR2-23 → SR2-24 → SR2-25 → SR2-26 → SR2-27 → SR2-28 → SR2-30 → SR2-32 → SR2-33 → SR2-34 → SR2-35 → SR2-36 → SR2-37 → SR2-38（按协调员定夺 (a)）。
5. 需先定口径再修：SR2-29、SR2-31（阈值）、SR2-40（见“需 Meng 裁决的新项”）。
6. 文档 P2 批量修：SR2-39 → SR2-41 → SR2-42 → SR2-43 → SR2-44 → SR2-45 → SR2-46 → SR2-47 → SR2-48 → SR2-49（留档即可）→ SR2-50。
7. 测试 P2 批量补：SR2-51～SR2-78（随对应代码修法一起补；SR2-57 记为 Win11 真机手动核查项）。

## 审过且干净的地方（要点）

- **P0/P1 原项修到位**：SR-P0-1（孤儿扫描任务派生口径完整，含 `page-normalized.png` 与 `pages/` 枚举；旋转烘焙图只缺测试覆盖，见 SR2-69）、SR-P0-2（设置值改名 + 三处归一 + 旧值/未知值单测复核通过）、SR-P0-3（`.gitignore` 补 `assets/models/**/*.onnx`，`git check-ignore` 验证）、SR-P1-1（`ReviewBucket` 唯一共享谓词，三处同源）、SR-P1-2（保留任务重建同事务）、SR-P1-3（`deleteExam` 事务化 + `name=''` 已删）、SR-P1-5/6（Layer-2 归一化单函数，两处调用方一致）、SR-P1-7（打开队列先保存，打开时部分）、SR-P1-8（重框缩略图条隐藏）、SR-P1-9（自查取最近一次）、SR-P1-10+11（Top5 按题 id、排除未整理/已归档；分布含已掌握的残留见 SR2-29）、SR-P1-12（排序/页码只首次 `_load` 读默认）、SR-P1-13（跳过末因直接进重做）、SR-P1-14（图片 20MB 硬判）、SR-P1-15（`CompactSliceThumb` 补 `errorBuilder`）、SR-P1-16（YOLO 失败可重试）、SR-P1-17（同批去重）。
- **P2 原项修到位（抽查）**：SR-P2-1/2/4/5/7/8/9/11/12/13/14/15/16/17、SR-P2-18/19/20/21/22/23/24/25/26/27/28/29/30/31/32/33/34/35/36、SR-P2-37/38/39/40/41/42/43/44/45/46/47/48/49/54/57/58、SR-P2-59/60/61/62/63/65/67/68/69（服务层路径）/70（`rotateBox` 本身）/71/72/73/74/75/76/77（只动测试侧，产品代码未动）、SR-P2-78～90（文档）、SR-P2-91/92（行数修正、`dart format` 0 changed）——其余未列出的 P2 原项见各分报告“已核实干净”清单；本次 78 项均为 Batch 5 未修完、未修对或新引入的问题。
- **B5 覆盖完整性**：脚本核对 SELF-REVIEW 134 个编号在 B5 系列报告中全有、无多余编号；测试数 progression（628→635→661→674→674→778）各阶段一致；SR-P2-56（不修）与 SR-P2-77（只动测试侧）在 B5-SUMMARY、B5-P2 及分报告中交代清楚。
- **路径安全与主要事务边界**：`resolveDataPath` 默认拒绝对路径、`_deleteDataFileIfUnreferenced` 只接受 `slices/` 前缀、taskId 先验安全字符集、备份路径校验与 zip-slip 校验到位；`_deleteQuestionTxn`、`deleteFolderFromImpl`、`deleteSubjectFromImpl`、`deleteCollectTaskFromImpl`、`replaceQuestionBoxesAndSliceIntoImpl`、`saveReviewState`/`loadReviewState`、`clearReviewState` 均无新引入的事务外多步写。
- **YOLO 只接第 1 层**（阈值 0.45、NMS 0.5、letterbox 换算正确、失败不回占位框）、EXIF、PDF 上限与失败清理、旋转烘焙、zip 校验与 14 张备份表、复查提醒四条件、主题/字体单次缩放、启动页白名单、左导航角标与 5 科上限，均核实干净。
- **真实题隐藏区域开关、叠加层真实框/回退、单框旋转禁用、左右键/滚轮、删除确认统一 AlertDialog、多页未框页保留、文件夹必填与学科隔离、详情页学科不可改/答案默认隐藏/删后进下一题/三段默认折叠**，逐项核对无问题。
- **封面**：顶部无任何英文；书脊贴左边缘、通顶通底；样式与颜色两套独立系统；新学科封面默认灰色；三徽标始终显示；删除确认走模态弹窗。
- **复习错因治疗模型、学习报告结构、设置默认值**与 `AppSettings.defaults` 逐项一致，均核实干净。
