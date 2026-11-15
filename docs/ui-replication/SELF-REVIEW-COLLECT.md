# 最终自审报告：收集 / 整理 / 题目详情页

- 范围：`lib/modules/collect/collect_page.dart`（1316 行）、`box_editor.dart`（2021 行）、`collect_widgets.dart`（44 行）、`lib/modules/organize/organize_page.dart`（2794 行）、`lib/modules/detail/question_detail_page.dart`（1887 行）、`lib/widgets/widgets.dart`（`QuestionSlice`、`QuestionRegionOverlays`、`regionsOfQuestion`、`layer2BoxToSliceRect`、`realRegionRects`、`CompactSliceThumb` 相关段）及 `lib/services/import_service.dart`（`_importPdf` 相关边界）；另读 `docs/ui-replication/B4-COLLECT.md`、`B3-OVERLAY-LAYER2.md`、`B3-DELETE-CONFIRM.md`、`B3-P12-UNBOXED-PAGES.md`。
- 分支：`ui-replication`，Batch 1/2/3/4 未提交。只审不改：未改任何代码，未 commit/push，未跑全量测试。
- 方法：逐文件通读；`flutter analyze`（7 个文件）0 问题；写 2 个针对性探针单测验证最严重的两处 2 层框疑点，2/2 通过后已删除探针文件；跑测试前已备份演示库到 `~/workspace/demo-db-backup/quiz-master2.db.selfreview-collect`，跑完核对 `~/.local/share/quiz-master2/quiz-master2.db` md5 仍为 `8f7f9c64405dc6e484ac2bf8e5e1a807`（v1、9 题，未改动）。
- 结论：**P0：0 条；P1：4 条；P2：13 条**。没有发现丢整页、丢整题、框整体错位这类 P0；4 条 P1 都是“静默丢数据 / 静默覆盖”的正确性问题，其中 2 条已由探针在运行时证实。

---

## P1（4 条）

### P1-1 详情页“重新框选”：已存的 2 层内框在编辑器里不可见，双击进内框模式会造出 3 个默认框，确认后新旧内框重复入库

- 位置：`lib/modules/detail/question_detail_page.dart:309-314,330`；`lib/modules/collect/box_editor.dart:229-230,397,372`
- 现象：详情页 `_reworkBoxes` 把内框按裸 `parentBoxId` 分组（`inners[b.parentBoxId!]`），以 `initialInners` 传给编辑器；但编辑器内部约定键是 `'$page:$boxId'`——`_innersOf`（:229-230）、`_enterInnerMode` 的 `putIfAbsent`（:397）、`_confirmPendingType`（:765）、`_ingestDetected` 的换算（:372，`_inners['$page:${entry.key}']`）全是带页前缀的键。于是已存内框既不在非内框模式的框内嵌套显示（`_boxBody` :1745 也走 `_innersOf`），也不在内框模式出现；双击题级框进内框模式时 `putIfAbsent` 找不到旧框，当场凭空造 stem/option/figure 3 个默认框。确认时 `_currentDraft` 原样带回两套键，详情页 `innersFlat` 把所有值展平（`[...result.inners.values]`）一起入库，造成同一区域两个 stem 框。
- 复现 / 证据：探针（已删）用详情页同款调用复现——`initialInners: {'q1-box': [stem]}`，打开后 `find.text('stem 题干')` 为空；双击题级框后出现默认 stem；确认返回的 `result.inners` 同时含 `'q1-box'` 与 `'1:q1-box'` 两个键，展平后 stem 框 ≥2 个。既有测试 `test/detail_page_test.dart:683-763` 只断言了 1 层框数为 1，未断言 2 层框数，所以没拦住。
- 后果：用户以为内框还在、实际看不见也改不了；一旦双击进内框模式再确认，库里多出重复内框，之后每次重框都会继续叠加。叠加层 `realRegionRects` 同区域取第一个，重复框还让“取第一个”的不确定性（P2-9）更容易踩中。
- 修的方向：二选一，修调用方或修编辑器入口，二者取其一即可——（a）详情页传 `initialInners` 时把键改成 `'$page:$parentBoxId'`；（b）`showBoxEditorDialog` / `_BoxEditorDialog.initState` 入口处把裸键统一归一化成带页前缀。建议同时在既有重框测试里补断言：确认后 `replaced` 的 2 层框数与类型与入库前一致，且不再双击时不凭空多框。

### P1-2 收集页“继续修框”：草稿里的 2 层框被混进 `initialBoxesByPage`，拖动 / 删除静默失效，确认拆题时直接丢弃

- 位置：`lib/modules/collect/collect_page.dart:362-364,385-396`；`lib/modules/collect/box_editor.dart:229-230,629-690`；`lib/modules/collect/collect_page.dart:545`
- 现象：`_openBoxEditor` 从 `boxesForTask` 取回的草稿是 1 层 + 2 层扁平列表，`draftsByPage` 按页分组时不分层，全部塞进 `initialBoxesByPage`，且根本不传 `initialInners` / `initialStandalone`。编辑器里这些 2 层框能显示、能选中，但 `_replaceBox` 的 2 层分支只在 `_inners` / `_standaloneInner` 里找（:662-690），`_deleteSelected`（:629）删的也是那两个 map，找不到就静默无操作；确认拆题时 `boxesByQuestionId[qid] = [box, ...?result.inners['$p:${box.id}']]`（:545）只取 1 层框 + `inners` map 里的子框，`boxesByPage` 里的 2 层框既不挂到任何题、也不进 `saveDraftBoxes` 的回写（`saveDraftBoxesIntoImpl` 的展平只认 `inners['$page:${b.id}']`），随原任务删除一起消失。
- 复现 / 证据：探针（已删）用收集页同款调用复现——`initialBoxesByPage: {1: [layer1, stem]}`：选中 stem 点“删除选中框”后框仍在；确认后 `result.boxesByPage[1]` 仍有 2 个框而 `result.inners` 为空。复现路径：修框时画一个 stem/option/figure 框（或进内框模式改框）→ 取消（草稿已保存）→ 重新点“继续修框” → 再确认拆题，2 层框即丢。
- 后果：与 B3 决定的“手动 2 层框保留不动、不删数据”直接冲突；用户在编辑器里看到框、拖不动删不掉、确认后悄悄没了，全程无任何提示。
- 修的方向：在收集页 `_openBoxEditor` 里把草稿按层拆开再传编辑器——1 层进 `initialBoxesByPage`，有 `parentBoxId` 的 2 层按 `'$page:$parentBoxId'` 进 `initialInners`，无主的进 `initialStandalone`（与 `_ingestDetected` :370-380 的分组口径一致）；或在编辑器 `initState` 里对 `initialBoxesByPage` 做一次同款拆分。修后补测试：画 2 层框 → 取消 → 重开 → 确认，2 层框仍在且可拖动/删除。

### P1-3 整理页：打开队列层不保存当前表单，队列里的批量操作用打开时的快照覆盖，会把未保存的表单改动静默抹掉

- 位置：`lib/modules/organize/organize_page.dart:345`（`_openQueue`）、`:2199`（`_batchTagRedo`）、`:2208`（`_batchAddFolder`）、`:2270`（`_batchConfirm`）
- 现象：`_openQueue` 是同步方法，不调 `_saveCurrent()`；而队列里的跳转（`_jumpToQuestion` :398）与改排序（`_applyQueueSort` :413）都先保存当前题。弹出层拿到的是打开时 `List.of(_queue)` 的快照，批量打标签 / 批量加文件夹 / 批量确认整理都用快照里的旧 `Question` 做 `repo.save(q.copyWith(...))` 整行覆盖。随后 `_closeQueue` → `_refresh` → `_loadForm` 从库重读，表单里未保存的改动（文件夹、标签、答案、错因等）全部消失，无提示。
- 复现：整理页改了当前题的文件夹或标签（别点保存/确认）→ 点“队列” → 勾上这道题 → “批量加入该文件夹”或“批量打标签 #需重做”或“批量确认整理” → 关队列回来，刚才在表单里的改动没了。
- 后果：用户以为“切到别的题才自动保存”的承诺（`_workActs` 文案）也覆盖队列操作，实际丢改动；批量确认整理还会把题按旧文件夹归档。
- 修的方向：`_openQueue` 改成异步，先 `await _saveCurrent()` 再弹层（与 `_jumpToQuestion` / `_applyQueueSort` 同款）；或让批量操作只改自己负责的字段时先重读最新行再合并。单删（`_deleteOne`）是显式删除，不受影响。

### P1-4 详情页“重新框选”：缩略图条按 `1..pageCount` 画，`pageCount` 恒为 1，源页 ≥2 的题点缩略图会切到一个不存在的“第 1 页”

- 位置：`lib/modules/detail/question_detail_page.dart:320-325`（`page: page, pageCount: 1`，`page` 是 `q.sourcePage`）；`lib/modules/collect/box_editor.dart:1533`（`for (var p = 1; p <= widget.pageCount; p++)`）、`:440-460`（`_switchPage`）
- 现象：重框编辑器只有一页底图（`pageImagePath` 就是该题所在页），但底部缩略图条仍按 `pageCount` 画出“第 1 页”。若该题来自 PDF 第 2 页及以后（`sourcePage ≥ 2`），`_currentPage` 初始是 2/3，点一下唯一的缩略图就 `_switchPage(1)`：`_boxesByPage[1]` 不存在，画布上的框全消失（底图仍是原页图，因为 `_currentPageImagePath` 回退到 `pageImagePath`，更具迷惑性）；此时再画的新框进 `boxesByPage[1]`，确认时详情页只读 `result.boxesByPage[sourcePage]`，新画的框被无声丢弃；若直接点确认，`newLayer1` 仍是原页的框，倒不会丢数据，但用户会以为框丢了。
- 复现：PDF 第 2 页及以后的题 → 详情页“重新框选这道题” → 点底部唯一的“第 1 页”缩略图 → 框消失；再画框、确认，新框不生效。
- 修的方向：重框模式下缩略图条只显示当前页一格（或直接隐藏整条 `_thumbStrip`，`pageCount == 1` 时不画切换条）；`_switchPage` 在 `pageCount == 1` 时拒绝切换到非当前页。顺带修文案：缩略图下标应显示真实页码（`sourcePage`）而非 1。

---

## P2（13 条）

### P2-1 切页自动检测只认 1 层框：只有独立题内框的页切走再回来会被重检测覆盖，独立内框丢失

- 位置：`lib/modules/collect/box_editor.dart:464-480`（`_autoDetectIfEmpty`）、`:370-380`（`_ingestDetected`）
- 现象：切页时的检测门控是 `(_boxesByPage[page] ?? []).isNotEmpty`，而 `_boxesByPage` 只存 1 层框；一页如果只有用户手画的独立题内框（`_standaloneInner`），门控误判为空页，跑一次检测；`_ingestDetected` 在检测无孤儿框时 `_standaloneInner.remove(page)`，手画的独立内框被清掉。`_openBoxEditor` 的首页面门控用的是 `draftsByPage[page]`（含 2 层），口径不一致。
- 修的方向：门控改成 1 层框、已挂内框、独立内框三者任一非空即跳过；或 `_ingestDetected` 在“替换”语义之外保留已有的独立内框。

### P2-2 “恢复自动框”的手动判断只认 1 层框：手画的独立题内框不弹确认就被替换掉

- 位置：`lib/modules/collect/box_editor.dart:495`（`hasManual = _boxes.any((b) => b.origin == 'manual')`，`_boxes` 只有 1 层）
- 现象：B3 把 `hasManual` 从恒真改成只认 `origin == 'manual'`，但检查范围仍只有 1 层框；手画的 stem/option/figure 独立内框（同样是 `origin == 'manual'`）不会触发“用自动框替换当前页的手动框？”确认，点“恢复自动框”后 `_ingestDetected` 直接覆盖。
- 修的方向：`hasManual` 同样检查 `_inners` 与 `_standaloneInner` 里 `origin == 'manual'` 的框。

### P2-3 重框模式“恢复自动框”只换 1 层框坐标，旧内框不跟随也不钳制

- 位置：`lib/modules/collect/box_editor.dart:543-600`（`_restoreAutoBoxForRework`）
- 现象：按 IoU 挑到检测框后只 `list[i] = clampToPage(picked.copyWith(id: target.id))`，`_inners` 里挂在该题下的旧内框坐标原样保留；新框移动/缩放后，旧内框可能落在新框外，确认后照此入库。草稿模式的 `_restoreAutoBoxes` 是整页替换（含内框重分组），口径不一致。
- 修的方向：替换后把该题的内框按新旧框的相对位置换算（或至少用 `_clampInner` 钳进新框），并在确认前校验内框是否仍在外框内。

### P2-4 内框模式下鼠标左键点空白处不退出，与帮助文案承诺不符

- 位置：`lib/modules/collect/box_editor.dart:1393` 起（画框层 `onPointerDown` 遇鼠标直接返回）、`:1168` 起（祖先级画布 `Listener` 只处理右键）、`:990-1000` 提示文案
- 现象：帮助与底部提示都写“点画布空白处、右键单击或按 Esc 退出内框模式”。触摸点空白处会经画框层 `_onDrawStart` → `_onDrawEnd`（小框当点击）退出；右键单击与 Esc 也能退；但鼠标左键点空白处没有任何处理（画框层忽略鼠标，祖先 Listener 只接右键），用户只能右键/Esc。
- 修的方向：祖先级 `Listener` 的 `onPointerDown` 里，鼠标左键落在画布空白处且处于内框模式时调 `_exitInnerMode()`（注意别抢框的拖动：只在未命中任何可交互框时退出，可复用 `_pointHitsInteractive`）。

### P2-5 确认拆题中途失败会留孤儿切片/烘焙页图；保留任务重建是两步写库、非事务

- 位置：`lib/modules/collect/collect_page.dart:505-575`（逐页写切片/烘焙图，`catch` 只提示 + `_load`）、`:576-620`（`confirmSplit` 后 `saveCollectTask(retained)` 与 `saveDraftBoxes` 两次 await，无 try/事务）
- 现象：切片是“先写盘、再进事务”，某页裁剪失败时前面已写的切片 PNG 与烘焙页图留在 `slices/` / `imports/<id>/pages/` 里，无库记录、无清理；四步事务本身失败时同理。保留任务重建分两步：第一步成功、第二步抛错时，任务已回“待框选”但未框页的草稿内框与旋转角没写回，且异常直接抛到 `_openBoxEditor`（无 try），无任何提示。
- 修的方向：失败时删除本次确认新建的切片/烘焙文件（记下已写路径清单再清）；保留任务重建包进一次事务或至少 try/catch + 失败提示与回滚。注意这不影响“未框页保留”本身的设计。

### P2-6 `_importPdf` 末尾的成功写库仍在 try 之外，库写失败会逃出 `enqueue`、任务卡“导入中”

- 位置：`lib/services/import_service.dart:403`（`await _db.upsertCollectTask(done)`，在渲染 try 块之后）；`:267-273`（`enqueue` 调 `_importPdf` 未包 try，之后又补一次 `upsertCollectTask`）；`lib/modules/collect/collect_page.dart`（`_importFiles` / `_pickFiles` 只有 `finally`，无 catch）
- 现象：B3 已在 `P12` 报告里记过此遗留，代码现状仍是如此：读页数与渲染两段都有 catch 兜底，但最后一次 `upsertCollectTask` 抛错（如库损坏）时异常一路逃出 `enqueue` → `_importFiles` → `_pickFiles`，无提示、无失败任务，库里任务行停在 `importing`，列表也停在旧状态。
- 补充：`_importPdf` 的空间预估（:357-363）是 `used + fileSize + total*2MB`，但 `used` 统计时原文件副本已经拷进库，`fileSize` 被重复算了一次——只会偏保守（接近 2GB 上限时可能误报“空间不足”），不丢数据。
- 修的方向：把末尾写库包进 try，失败走 `_failAndClean`（与读页数/渲染段同款）；空间预估扣掉已计入的原文件大小。

### P2-7 `CompactSliceThumb` 的 `Image.file` 没有 `errorBuilder`，损坏切片会显示 Flutter 报错占位

- 位置：`lib/widgets/widgets.dart:609`（`Image.file(sliceFile, fit: BoxFit.cover, cacheWidth: 128)`，无 `errorBuilder`）；对照 `:393`（`QuestionSlice` 有 `errorBuilder`，走缺图占位）
- 现象：文件存在但解码失败（损坏 / 非图片内容）时，错题本紧凑列表里出现 Flutter 的灰底报错图，而非“加载失败”占位。`failed` 标志位与“文件不存在”两条路都有占位，唯独“存在但解不出来”这条漏了。
- 同款：`lib/modules/collect/box_editor.dart:1352` 的页图 `Image.file` 也无 `errorBuilder`，但有 `_pageImageFailed` 门控（`_loadPageImageSize` 用同一文件解码先行判断），风险低得多，顺带补即可。
- 修的方向：给 `CompactSliceThumb` 的 `Image.file` 加与 `QuestionSlice` 同款 `errorBuilder`，走现有 `missingRealImage` 的“图片缺失 / 加载失败”分支。

### P2-8 叠加层换算取第一个 1 层框：同一题有多个 1 层框时，挂在第 2 个框下的 2 层框会被按第 1 个框换算错位

- 位置：`lib/widgets/widgets.dart:71-97`（`realRegionRects`，第一个 1 层框即 `break`，其后所有 2 层框都按它换算）
- 现象：正常拆题是一题一框，但详情页重框允许一题多个 1 层框（`_reworkBoxes` 不限制 `newLayer1` 个数），此时属于第 2 个 1 层框的 2 层框仍按第 1 个框的坐标换算，叠加层位置错误。
- 修的方向：按 `parentBoxId` 把 2 层框归属到各自的 1 层框再换算；或在重框入口限制一题只能保留一个 1 层框（与拆题时一题一框的模型一致）。

### P2-9 叠加层“同区域多框取第一个”无确定性优先级（B3 遗留，属实）

- 位置：`lib/widgets/widgets.dart:71-97`（`realRegionRects`，`if (out.containsKey(b.type)) continue`）；`lib/data/db_collect.dart:205-222`（`boxesForPageImageFromImpl` 无 `ORDER BY`）
- 核实：属实。`boxesForTask` 有 `ORDER BY page ASC, id ASC`，但 `boxesForPageImage` 没有，行序即返回序（通常 rowid 序），同一区域多个框时画哪一个不确定。影响面：目前主要在演示题/老题的叠加层；P1-1 的重复入库会放大它（重复的 stem 框谁先返回、画谁，全凭行序）。
- 修的方向：`boxesForPageImageFromImpl` 加 `ORDER BY page ASC, id ASC`（与 `boxesForTask` 对齐），或 `realRegionRects` 明确优先级（如取面积最大者）并写进注释/测试。

### P2-10 红色无框警告对“从未打开过的新导入任务”也会显示（B3 遗留，属实，等 Meng 定）

- 位置：`lib/modules/collect/collect_page.dart:107-150`（`_load` 按草稿框逐页算未框页）、`:1124-1136`（行上警告）
- 核实：属实。刚导入、还没打开过修框的任务没有草稿框，按“有未框页即警告”的字面规则同样显示“这张图还没有框”。B3 报告已记录，是否收窄到“部分框过 / 打开过”待 Meng 决定；本次自审不替他定，只确认行为与报告一致，无其他副作用（警告只影响行上文案，不影响导入/修框流程）。
- 修的方向：等决定；若收窄，需在任务行记录“是否打开过修框 / 是否已有任意草稿框”的信号（目前 `_unboxedPagesByTask` 只有未框页数，区分不开）。

### P2-11 详情页新建文件夹：点对话框外关闭会被当成“放在顶层”创建，没有真正的取消路径

- 位置：`lib/modules/detail/question_detail_page.dart:595-630`，注释 `:606` 自述“点空白处关闭返回 null 与选‘顶层’同义，都当顶层处理”
- 现象：`_newFolder` 先弹输入框问名，再弹 `SimpleDialog` 问“放在哪里”，选项只有“顶层”和各顶层文件夹，没有“取消”；点框外关闭返回 null，代码当顶层创建。用户本想取消，却建了一个顶层文件夹（还会 `setState` 选上它并标脏）。
- 修的方向：`SimpleDialog` 加“取消”选项，用可区分的哨兵值（如空字符串）区分“取消”与“顶层”，点框外也按取消处理。

### P2-12 自定义错因与固定枚举同名时，详情页保存会静默丢掉，整理页会造成错因重复

- 位置：`lib/modules/detail/question_detail_page.dart:231-244`（`customNew` 过滤掉所有固定枚举名）；`lib/modules/organize/organize_page.dart`（`_addCustomType` 不校验是否与固定枚举或已选固定项重名）；`lib/models/models.dart:329`（`allCauses => [...errorTypes, ...customErrorTypes]`，不去重）
- 现象：详情页“新建错误类型”里输入“其他”这类固定名，芯片显示已选，保存时 `customNew` 把它滤掉，`_editErrorTypes` 里也没有，错因直接消失；整理页同名自定义会原样入库，`allCauses` 出现两次“其他”，详情页副标题的错因 pill 与复习记录的错因行都会重复（`syncCauseRecords` 内部用 `toSet` 去重，复习页不受影响，纯显示重复）。
- 修的方向：新建自定义时若与固定枚举同名，直接当作选中对应固定项（并提示），不再进自定义集合；或保存时把同名自定义合并进 `_editErrorTypes`。

### P2-13 毫秒级时间戳 id：文件夹 / 试卷 / 知识点快速连点可能互相覆盖

- 位置：`lib/modules/organize/organize_page.dart`（`_submitNewFolder`、`_submitNewExam` 的 `'folder-${ms}'` / `'exam-${ms}'`）；`lib/modules/detail/question_detail_page.dart`（`_newFolder`、`_newExam`、`_newKnowledgePoint` 同款）；`lib/modules/collect/collect_page.dart`（`_failTask` 的 id 还叠加 `fileName.hashCode`，同名同毫秒两次失败会互相覆盖）
- 现象：新建类 id 只有毫秒时间戳，没有随机后缀；同一毫秒内两次创建（如双击“添加”）会生成相同主键，后一次 `save` 覆盖前一次，前一个实体无声消失。框 id（`AppDatabase.newBoxId`，8 位随机十六进制）与拆题 id（`'import-$ts-$p-$i'`，含页与序号）已有防撞手段，新建文件夹/试卷/知识点没有。
- 修的方向：统一用 `newBoxId` 同款随机后缀，或复用一个 `newId(prefix)` 工具；`_failTask` 同理。

---

## 其他 P2 级小项（已核实，附在 P2 内不另编号）

- **整理页修框切片整题卡未传学科对象**：`lib/modules/organize/organize_page.dart:902` 的 `QuestionSlice(question: q, maxHeight: 220)` 没传 `subject`，其余调用处（同页 `_paperImage`、详情页、错题本）都传；仅当切片缺图走占位时，学科名/图标回退到 `Subject.byId`（新学科会显示成数学）。补传 `_subjectOf(q.subjectId)` 即可。
- **`_donePages` 只是本页装饰态**：`lib/modules/collect/box_editor.dart:198,1595-1615`，“本页修完 ✓”不校验（0 框也能打勾）、不进草稿、不随取消保存，重开编辑器即丢；确认也不看它。现状无害，但按钮文案会让用户误以为“打勾 = 已保存/已确认”。
- **切页与取消保存草稿无 try**：`lib/modules/collect/box_editor.dart:440-460`（`_switchPage`）、`_foot` 的取消按钮先 `await _saveDraftIfNeeded()` 再 `pop`；保存抛错时切页直接抛（`onTap` 未接异常）、取消时对话框关不掉且无任何提示。包 try + 失败提示即可。
- **`firstWhere` 无 `orElse` 的硬查**：`lib/modules/collect/box_editor.dart:397`（`_enterInnerMode`）、`:826-835`（`_onDrawStart` / `_onDrawUpdate` / `_onDrawEnd` 里按 `_innerModeBoxId` 找外框）、`:669`（`_replaceBox` 内框分支的 `_inners[key]!`）。目前可达路径较窄（删框时会清内框模式），但一旦命中就是 `StateError` 崩溃；建议补 `orElse` 兜底或进入内框模式前校验。
- **`CollectStatus.done` 无赋值处**：全仓 grep 无任何 `= CollectStatus.done` / `status: CollectStatus.done`，`lib/modules/collect/collect_page.dart:107-150` 的 `splitPagesBySource` 与 `:629-640` 的 `_splitPagesFor` 里对 `done` 的分支实际走不到；`_statusPill` / `_taskActions` 里 `done` 的行也一样。现状无害（防御性代码），但“已整理任务行”的删除确认实际走的是 `pendingOrganize` 分支，注释里“待整理 / 已整理”的说法应以此为准。

---

## 死代码 / 无用参数 / 过时注释

- **确实无调用方的公开组件**：`lib/widgets/widgets.dart:681` 的 `DashedDivider` 与 `:762` 的 `InfoChip` 在 `lib/` 内没有任何调用点（只剩 `uikit.dart` 注释里提到它们的名字）；两处文档注释还写着“九页调用处不动 / 签名不变”，与现状不符。`EmptyState`（:1080）仍有调用（详情页题不存在时），不是死代码。修的方向：确认无外部引用后删除两者，或留一个并补回调用；至少修正注释。
- **重复实现**：`lib/modules/organize/organize_page.dart:122` 与 `:2122` 的 `_subjectInitial`、` :519` 与 `:2131` 的 `_dateText`，父页与 `_QueuePopupState` 各一份，一字相同。抽到一处共用即可。
- **B4 拆分未留死代码**：`collect_page.dart` 删掉的 3 个 import（`dart:math` / `dart:ui` / `gestures`）确实只被编辑器用；`box_editor.dart` 的 import 子集完整；`collect_widgets.dart` 只有 `DashedDropPainter` 一个公开类且两处调用点（`collect_page.dart:971`、`box_editor.dart:1786`）已同步改名；全仓无 `_DashedDropPainter` 残留。见下节。
- **注释与行为一致、无需动的**：`collect_page.dart` 头注释“系统拖拽导入未实现，只写占位文案”属实；`box_editor.dart` 头注释“单框旋转已禁用，圆柄已去掉”属实（只有四角缩放柄 `_resizeHandle`，无旋转柄）；`widgets.dart` 的 `regionsOfQuestion` 文档与 P1-1 降级口径一致。

---

## B4 拆分完整性结论：接线完整，无行为变化

- `collect_page.dart` 经 `export 'box_editor.dart'` re-export，`lib/modules/detail/question_detail_page.dart:34`（`import '../collect/collect_page.dart'`）与 `lib/app.dart` 一字未改即可继续用 `showBoxEditorDialog` / `BoxEditorMode`（详情页 `:320` 调用 `BoxEditorMode.rework`）；全仓无其他文件直接 import `box_editor.dart`，无重复定义。
- 拆出内容与 `B4-COLLECT.md` 所述一致：`box_editor.dart` 是原 L1352–3349 逐字移出（含末尾 `extension _BoxEdit on QuestionBox`），`collect_widgets.dart` 是原 `_DashedDropPainter` 仅改名；`collect_page.dart` 仍 1316 行，`_CollectPageState` 未再拆（任务行/筛选仍与 state 深度耦合，报告已说明，属实）。
- `flutter analyze`（7 个文件）0 问题；两处探针单测（编辑器入口行为）2/2 通过后已删除。
- 唯一遗留：`collect_page.dart` 仍有 1316 行，后续如需再拆任务行/筛选需另立项——不是缺陷，不列入问题清单。

---

## 审过且干净的地方（逐项核对无问题）

- **真实题不显示区域开关、只留整题切片**：`widgets.dart:35-43`（`sliceText` 为空返回空列表）；`organize_page.dart:785-795`（`_leftPane` 整行隐藏开关）、`:860-890`（`_regionToggles` 空兜底）、`:787,813`（叠加层挂载但 `visible` 为空不画框）；`_slicesSection` 真实题只剩“整题框切片”一张卡。
- **叠加层有真实框用真实框、无框回退示意框**：`widgets.dart:44-97`（`layer2BoxToSliceRect` 换算 + 钳制、`realRegionRects`）、`:133-141`（`region()` 有真实框用真实框、无则示意框）；`organize_page.dart:219-263`（切题先清旧框再读框，`mounted` + 同题校验防竞态）；`_loadRealBoxes` 只读 `questionId` 匹配的行，同页别题的框被过滤。
- **单框旋转禁用、整页旋转保留**：`box_editor.dart:1667,1776`（无旋转圆柄、只有四角缩放柄）；`_rotatePage`（:607）按页旋转且重框模式禁用（按钮只在 draft 模式渲染，:1112-1119）。
- **左右键 / 滚轮**：祖先级画布 `Listener`（:1168 起）右键任何位置拖出新框（`fromRightDrag` 跳过框内拦下，`_onDrawStart` :821 起）、右键单击取消（内框模式退出，非内框模式无动作）、左键落在框上锁滚动拖框、落在空白处平移；滚轮在图上缩放、在图外滚动（内层 `Listener.onPointerSignal`）。B3 的“右键起点在框上画新框”已由该 Listener 覆盖。
- **删除确认统一模态弹窗**：收集 `_deleteTask`（`collect_page.dart:670`，含失败任务 `:1299` 改走它）、详情 `_askDelete`（`detail:450`）、整理队列 `_askConfirm` + `ModalBarrier` + `AlertDialog`（`organize_page.dart:2159-2172,2512-2540`，Esc 先关确认框再关队列层）、文案“删了就没了，确定吗？”三处一致；行内确认条已无残留（详情 `_buildConfirmBox` 仅剩取消编辑三选一用途，`detail:1533,1842`，不是删除确认，保留正确；整理页 `_pendingDeleteId` / `_batchDel` 等已删；导入中/排队中的“取消导入/取消排队”仍直接删，属取消进行中任务而非删除确认点，与 B3 审计表第 3 行一致）。
- **多页 PDF 未框页不丢**：`collect_page.dart:424-480`（确认前报未框页数、取消则什么都不拆）、`:576-620`（只拆有框页，同 id 重建回 `needBox`、从首个未框页继续、页图目录不变）、`:629-640`（`_splitPagesFor` 防重复拆）、`:1124-1136`（行上红色警告，`palette.errInk`）。
- **整理表单**：文件夹必填（`_confirmCurrent` 空文件夹拦下并展开文件夹区；`_missingLine` 只数文件夹）、其余可选且空字段显示“（可选，还没填）”；文件夹按学科隔离（`_loadFolders` 按当前题学科取、详情页编辑态只列本科文件夹、队列批量文件夹只列当前科学科）；各区独立多开（每区独立 bool / `_expanded` 集合，无单开互斥）。
- **详情页**：学科不可改（展示与编辑态都是纯文本字段）；答案默认隐藏（`_answerVisible = false`，切题/删题后复位）；删除后自动进下一题（`_doDelete` 取 `_orderIds[idx+1]`，无下一题才 pop）；三段默认折叠（`_expanded = {}`，切题/删题后清空）。
- **整理表单保存不丢字段**：`_formQuestion`（`organize_page.dart:270-290`）覆盖文件夹/试卷/知识点/错因/自定义/标签/答案/解析/笔记，`clearExamId` / `clearAnswer` 等标志处理了 `copyWith` 传 null 表“保持”的语义；详情 `_saveEdit`（`detail:228-280`）逐字段对照 `Question` 模型全量保留（含图片链路 8 个字段），无遗漏。
- **队列切换不丢数据（除 P1-3 的批量覆盖外）**：`_goTo` / `_jumpToQuestion` / `_applyQueueSort` / `_openDetail` / `_confirmCurrent` 均先 `_saveCurrent()`（含 `syncCauseRecords`）；`_refresh` 切题后 `_index` 越界会钳制到末尾。
- **页面刷新**：`_load` / `_refresh` / `_loadForm` 的异步读框有 `mounted` 与同题校验；`_loadRealBoxes` 在 `pageImagePath` 为空时不读库。
- **B3 遗留核实**：`_restoreAutoBoxes` 的 `hasManual` 已只认 `origin == 'manual'`（`box_editor.dart:495`，B3-P12 的修复属实，但范围漏了独立内框，见 P2-2）；`_importPdf` 读页数与渲染两段 catch 兜底属实（`import_service.dart:337-348,381-390`，但末尾写库仍在 try 外，见 P2-6）；`CompactSliceThumb` 无 `errorBuilder` 属实（见 P2-7）；叠加层取第一个无确定性优先级属实（见 P2-9）。

---

## 修的建议顺序

1. 先修 P1-1 + P1-2（同一根因：编辑器内外 2 层框的键/分层口径不统一；修一处归一化函数，两处调用方都受益）。
2. 再修 P1-3（队列打开前先保存）与 P1-4（重框隐藏/修正缩略图条）。
3. P2 按“丢数据”优先：P2-1、P2-2、P2-3（2 层框相关）→ P2-5、P2-6（失败路径孤儿/卡住）→ 其余。
4. 死代码（`DashedDivider` / `InfoChip`）与重复实现可随手清，不阻塞。
