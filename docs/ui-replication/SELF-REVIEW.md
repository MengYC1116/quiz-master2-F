# quiz-master2 最终自审报告（SELF-REVIEW）

- 日期：2026-11-14
- 工作树：`~/workspace/quiz-master2-UI`，分支 `ui-replication`，本地 HEAD `bca8586`
- 范围：Batch 1/2/3/4 + 书脊修复全部完成、未提交、未推代码后的全代码通读（`lib/` 全部 41 个 Dart 文件，约 22,015 行）
- 方式：6 组并行分片通读（数据层 / 收集·整理·详情 / 错题本·复习·报告·首页 / 服务层·模型·主题·外壳 / 文档与决定一致性 / 第四批拆分完整性验证），只审不改；疑点用 `flutter analyze` 与针对性单测证实；分报告见 `SELF-REVIEW-DATA.md`、`SELF-REVIEW-COLLECT.md`、`SELF-REVIEW-WRONGBOOK.md`、`SELF-REVIEW-SERVICES.md`、`SELF-REVIEW-DOCS.md`、`SELF-REVIEW-SPLIT.md`
- **结论：共 134 项：P0 3 项，P1 39 项，P2 92 项。** 其中跨组重复已合并 3 项（CompactSliceThumb errorBuilder、_importPdf 写库在 try 外、封面三数口径），收集组未编号的 7 项 P2 小项已补计入内。
- P0 定义：常规操作可达的错删/丢数据/一点就坏；P1：正确性 bug、非事务多步写、计数错误、与既定决定直接冲突；P2：完整性风险、边界、死代码、文档过期、性能。
- 已定事项（只记一笔，不算新问题）：v1 库直接删除（§6 第 1 条，Meng 已定）、多值字段 JSON、存储上限 2GB（仅导入路径执行，备份恢复绕过见 SR-P2-5）、老收集任务删除语义、备份含文件 zip、Layer-2 暂缓（`intraEnabled=false`）、`double` 封面折角由 Meng 与 CodeBuddy 协调（未动）。

## P0（3 项）

### SR-P0-1 孤儿扫描把未拆分 PDF 任务的页图当孤儿，设置页一键清理会删掉它们
- 位置：`lib/data/db_orphans.dart:9-64`（`_referencedRelativePaths`、`scanOrphanFilesFromImpl`）；调用链 `lib/modules/settings/settings_page.dart:167-209`
- 现象/后果：引用口径只收 `questions.source_path/page_image_path/slice_path` + `collect_tasks.source_path`。未拆分的 PDF 任务 `source_path` 只是 `imports/<id>/original.pdf`，渲染出的页图在 `imports/<id>/pages/page-001.png`，没有任何行引用，扫描会把全部页图列为孤儿；设置页一点确认，任务页图全灭；修框页按“页图缺失明确报错、不开编辑器”处理，且无重新渲染入口，任务只能删掉重导，草稿框实际作废。同理图片任务的 EXIF 归一化副本 `imports/<id>/page-normalized.png` 也无行引用（此处有回退到原图，影响较小）。
- 证据：代码直接可判定；复现：导入多页 PDF、不拆题 → 设置 → 数据组 → 孤儿扫描列表出现 `imports/<taskId>/pages/*.png`。
- 修的方向：引用口径补两条——所有 `collect_tasks` 行的 `imports/<taskId>/` 整个目录视为被引用（或至少 `pages/` + `page-normalized.png` + `original.*`）；或扫描时跳过仍有存续任务的目录。修后补单测：建一个 needBox 的 PDF 任务（只有 `source_path`，无题），扫描结果必须为空。

### SR-P0-2 设置里选“学科首字母”排序，进错题本列表即触发 DropdownButton 断言
- 位置：`lib/modules/settings/settings_page.dart:1004-1006`（选项 `'subject'`）→ `lib/modules/wrongbook/wrongbook_page.dart:179-180`（`_load` 置 `_sort`）→ `lib/modules/wrongbook/wrongbook_list.dart:133-153`（下拉）→ `wrongbook_page.dart:446-473`（`_filteredAll` 的 `switch (_sort)`）
- 现象/后果：设置页“默认排序”提供 `'subject'`（模型注释 `models.dart:552` 亦写 `wrongbookSort = 'new' // new / old / subject`），但列表页排序下拉只有 `new / old / subj-asc / subj-desc / status-asc / status-desc` 六项，没有 `'subject'`；`_filteredAll` 也没有 `case 'subject'`，落入 `default`（时间新→旧）。debug 下抛 `There should be exactly one item with [DropdownButton]'s value: subject`；release 下下拉显示异常。等于设置里一个公开选项一点就坏，且即使不崩、排序也静默回落到默认。
- 证据：四处代码链即证据（`grep wrongbookSort lib/ test/` 显示除设置页与模型外只有 `wrongbook_page.dart:179-180` 两处引用，无任何消费 `'subject'` 的分支）。**注意：探针 widget 测试曾尝试 live 复现，但同期另一工人在同一树跑 17 个文件的批量测试占住构建缓存，探针 8 分钟无输出，已主动停掉并清理；本条定论建立在代码链 + DropdownButton 契约上，修后须用单测复核。**
- 修的方向：二选一，需 Meng 定：(a) 设置项改名/改值，与列表页一致（`'subject'` 改为 `subj-asc` 或拆成两项 A→Z / Z→A），并在 `_filteredAll` 补对应 case；(b) 列表下拉补一个 `value: 'subject'` 的 item 并映射到 `subj-asc`。同时给 `_sort` 加兜底：未知值回落到 `_defaultSort` 或 `'new'`。修后加一测：`wrongbookSort='subject'` 的 FakeRepo 进列表不断言。

### SR-P0-3 38MB YOLO 模型文件没有任何 `.gitignore` 保护，一次 `git add .` 即入库
- 位置：`assets/models/question/yolo11s-question-v1.onnx`；`.gitignore`（全文 grep，无 `models`/`onnx` 规则）；`pubspec.yaml:33,37`
- 现象/后果：`git status` 显示 `?? assets/models/question/`（未入库、未忽略）；`git check-ignore` 确认 NOT IGNORED；`pubspec.yaml` 用 `- assets/models/` + `- assets/models/question/` 声明，模型打进包是正确的，但仓库层面无任何防线。一次习惯性的 `git add .` 就会把 38MB 二进制写进历史，之后清理历史的成本远高于现在加一行忽略规则。与既定决定“模型文件 38MB 不进仓库、Meng 自己放”直接冲突。
- 证据：Batch 3 汇总遗留第 1 点，属实（本次复核一致）。
- 修的方向：**等 Meng 决定**（Batch 3 待定事项）：在 `.gitignore` 加 `assets/models/question/*.onnx`（或 `assets/models/**/*.onnx`，保留 `assets/models/README.md` 入库）；并核对 `git ls-files assets/` 确认只有 README 在库内。

## P1（39 项）

### 数据层（SR-P1-1～SR-P1-4）

#### SR-P1-1 错题本封面三数与首页口径不一致（两处）
- 位置：`lib/data/repository.dart:66-80`（`dueToday`，首页用）vs `:105-136`（`subjectCounts`，封面用）；`lib/modules/home/home_page.dart:130-145`（焦点卡互斥拆分）；`lib/modules/wrongbook/wrongbook_shelf.dart`（封面 `_bookStat`）
- 现象/后果：(a) `dueToday` 算 `status != solved || isRecheckDue`，`subjectCounts` 的 `toReview` 只算 `rs.any(status != solved)`——一道题全部错因已解决、但有一条到了复查时间：首页算“要复习”，封面 `toReview` 为 0、`toRecheck` 为 1；(b) `subjectCounts` 两个 `if` 独立计数，一道题可同时计入要复习与待复查（注释亦明说），而首页焦点卡是互斥拆分（有未解决错因计待解决，只有复查到期才计复查，两者之和 = 要复习总数）。于是同一科：封面“要复习”不含纯复查题（比首页各科格少），封面“待复查”含混有未解决错因的题（比首页焦点卡“复查”多），封面两徽标之和还可能大于该科要复习题数。
- 证据：`subjectCounts`（`:130-136`）与首页拆分循环（`home_page.dart:138-145`）逐行对照即见；`isRecheckDue` 定义（`models.dart:137-144`：已解决且复查日 ≤ 今天）已核实。
- 修的方向：由 Meng 定唯一口径后统一：建议封面沿用首页互斥拆分（要复习 = 待解决数、待复查 = 仅复查数，两者之和 = `homeRevCounts` 该科数），或反之首页改双计；不要两处各自定义。最好把两处抽成一个共享谓词/函数；`subjectCounts` 返回三元组第三项 `solved` 的语义也应在注释里写清。

#### SR-P1-2 确认拆题：事务只包库内四步，未框页的“保留任务重建”在事务外，崩溃窗口丢任务 + 丢未框页草稿
- 位置：`lib/data/db_collect.dart:382-430`（`confirmSplitIntoImpl`，事务内删原任务全部草稿框 `:424`）+ `lib/modules/collect/collect_page.dart:569-616`（`_confirmSplit`：`confirmSplit` → `saveCollectTask(retained)` → `saveDraftBoxes(...)`，三次独立写库）
- 现象/后果：`confirmSplitInto` 无条件删掉原任务所有 `question_id IS NULL` 的草稿框（包括未框页的），然后调用方在事务外按同 id 重建保留任务并写回未框页草稿。`confirmSplit` 提交成功、重建还没发生时进程被杀/崩溃：原任务行已删、草稿框已删，保留任务不存在——未框页连同页图目录引用一起丢（页图文件还在盘上，但没有任务行指向它们，之后还会被孤儿清理当孤儿删掉，见 SR-P0-1）。即使不崩溃，`saveDraftBoxes` 抛错也会留下“任务在、草稿丢”的半截状态。
- 证据：代码走读可判定窗口存在：三段之间无任何事务/补偿。
- 修的方向：首选把“删原任务 + 建拆分任务 + 重建保留任务 + 写回未框页草稿”做进同一个 `confirmSplitInto` 事务（把 `unboxedPages` 草稿与保留任务行作为参数传进去）；退而求其次：`confirmSplitInto` 只删已确认页的草稿框，不删未框页的，调用方重建失败时草稿仍在。

#### SR-P1-3 `deleteExam` 三步写不在事务里，且第一步是无意义的 `name=''`
- 位置：`lib/data/db_catalog.dart:436-447`（`AppDatabaseCatalog.deleteExam`，extension 方法，无 `Impl` 版）
- 现象/后果：`update exams set name=''` → `delete exams` → `update questions set exam_id=null`，三段顺序 await、无事务。中间失败/崩溃会留下两种半截状态：试卷已删但题还指着已不存在的 `exam_id`（悬空引用；错题本按试卷筛题时这批题丢过滤）；或试卷还在但名字被清空成 `''`（学科管理里出现无名试卷）。第一步 `name=''` 没有任何作用——下一秒行就被删掉，纯属死步骤，疑似复制粘贴残留。B3 遗留“`deleteExam` 是否包事务”核实：不包，属实。
- 证据：与同文件 `deleteTagFromImpl`、`deleteKnowledgePointFromImpl`、`deleteChapterFromImpl`（事务版）对比，只有 `deleteExam` 没包事务。
- 修的方向：删掉 `name=''` 那行，剩余两步包进 `db.transaction`（仿 `deleteTagFromImpl` 的写法，最好顺手补一个 `deleteExamFrom` 可单测版）；调用方 `repository.dart:287`、`subjects_page.dart:285` 不用动。

#### SR-P1-4 `_importPdf` 末尾成功路径的 `upsertCollectTask(done)` 在 try 之外，写库失败逃出 `enqueue`、任务卡 importing、整批中断
- 位置：`lib/services/import_service.dart:403`（`_importPdf` 内最后的 `upsertCollectTask(done)`）；调用点 `:267-273`（`enqueue` 内 `final done = await _importPdf(...); await _db.upsertCollectTask(done);`，无 try 包裹）
- 现象/后果：读页数、渲染两个 try 都有兜底 catch（`:337-352`、`:371-386`），但渲染成功后写 `needBox` 状态这一步不在任何 try 里。此时若写库失败（磁盘满、库损坏、DB 锁），异常直接逃出 `enqueue`：本任务停在 `importing` 状态（页图已渲染完却无 `needBox` 行，界面无失败标记、无法重试），且同一批后面的文件不再处理，异常抛到调用方（收集页）层面。B3-SUMMARY 遗留点 3 核实：属实。触发概率低（只在写库恰好失败时），但失败模式是“卡死 + 整批中断”，不是“单个任务失败”。（收集组另核实：`_importFiles` / `_pickFiles` 只有 `finally`，无 catch。）
- 修的方向：`_importPdf` 末尾的 upsert 包进 try/catch，失败走 `_failAndClean`（或至少返回 failed 任务）；或 `enqueue` 的 `_importPdf` 调用点加 try/catch，把异常转成该任务的 failed 行并继续处理下一个文件。

### 收集 / 整理 / 详情（SR-P1-5～SR-P1-8）

#### SR-P1-5 详情页“重新框选”：已存的 2 层内框在编辑器里不可见，双击进内框模式会造出 3 个默认框，确认后新旧内框重复入库
- 位置：`lib/modules/detail/question_detail_page.dart:309-314,330`；`lib/modules/collect/box_editor.dart:229-230,397,372`
- 现象/后果：详情页 `_reworkBoxes` 把内框按裸 `parentBoxId` 分组（`inners[b.parentBoxId!]`），以 `initialInners` 传给编辑器；但编辑器内部约定键是 `'$page:$boxId'`——`_innersOf`（:229-230）、`_enterInnerMode` 的 `putIfAbsent`（:397）、`_confirmPendingType`（:765）、`_ingestDetected` 的换算（:372）全是带页前缀的键。于是已存内框既不在非内框模式的框内嵌套显示（`_boxBody` :1745 也走 `_innersOf`），也不在内框模式出现；双击题级框进内框模式时 `putIfAbsent` 找不到旧框，当场凭空造 stem/option/figure 3 个默认框。确认时 `_currentDraft` 原样带回两套键，详情页 `innersFlat` 把所有值展平一起入库，造成同一区域两个 stem 框。用户以为内框还在、实际看不见也改不了；一旦双击再确认，库里多出重复内框，之后每次重框都会继续叠加。
- 证据：探针单测（已删）用详情页同款调用复现——`initialInners: {'q1-box': [stem]}`，打开后 `find.text('stem 题干')` 为空；双击题级框后出现默认 stem；确认返回的 `result.inners` 同时含 `'q1-box'` 与 `'1:q1-box'` 两个键，展平后 stem 框 ≥2 个。既有测试 `test/detail_page_test.dart:683-763` 只断言了 1 层框数为 1，未断言 2 层框数，所以没拦住。
- 修的方向：二选一，修调用方或修编辑器入口，二者取其一即可——(a) 详情页传 `initialInners` 时把键改成 `'$page:$parentBoxId'`；(b) `showBoxEditorDialog` / `_BoxEditorDialog.initState` 入口处把裸键统一归一化成带页前缀。建议同时在既有重框测试里补断言：确认后 `replaced` 的 2 层框数与类型与入库前一致，且不双击时不凭空多框。

#### SR-P1-6 收集页“继续修框”：草稿里的 2 层框被混进 `initialBoxesByPage`，拖动 / 删除静默失效，确认拆题时直接丢弃
- 位置：`lib/modules/collect/collect_page.dart:362-364,385-396`；`lib/modules/collect/box_editor.dart:229-230,629-690`；`collect_page.dart:545`
- 现象/后果：`_openBoxEditor` 从 `boxesForTask` 取回的草稿是 1 层 + 2 层扁平列表，`draftsByPage` 按页分组时不分层，全部塞进 `initialBoxesByPage`，且根本不传 `initialInners` / `initialStandalone`。编辑器里这些 2 层框能显示、能选中，但 `_replaceBox` 的 2 层分支只在 `_inners` / `_standaloneInner` 里找（:662-690），`_deleteSelected`（:629）删的也是那两个 map，找不到就静默无操作；确认拆题时 `boxesByQuestionId[qid] = [box, ...?result.inners['$p:${box.id}']]`（:545）只取 1 层框 + `inners` map 里的子框，`boxesByPage` 里的 2 层框既不挂到任何题、也不进 `saveDraftBoxes` 的回写，随原任务删除一起消失。与 B3 决定的“手动 2 层框保留不动、不删数据”直接冲突；用户在编辑器里看到框、拖不动删不掉、确认后悄悄没了，全程无任何提示。
- 证据：探针单测（已删）用收集页同款调用复现——`initialBoxesByPage: {1: [layer1, stem]}`：选中 stem 点“删除选中框”后框仍在；确认后 `result.boxesByPage[1]` 仍有 2 个框而 `result.inners` 为空。复现路径：修框时画一个 stem/option/figure 框（或进内框模式改框）→ 取消（草稿已保存）→ 重新点“继续修框” → 再确认拆题，2 层框即丢。
- 修的方向：在收集页 `_openBoxEditor` 里把草稿按层拆开再传编辑器——1 层进 `initialBoxesByPage`，有 `parentBoxId` 的 2 层按 `'$page:$parentBoxId'` 进 `initialInners`，无主的进 `initialStandalone`（与 `_ingestDetected` :370-380 的分组口径一致）；或在编辑器 `initState` 里对 `initialBoxesByPage` 做一次同款拆分。修后补测试：画 2 层框 → 取消 → 重开 → 确认，2 层框仍在且可拖动/删除。

#### SR-P1-7 整理页：打开队列层不保存当前表单，队列里的批量操作用打开时的快照覆盖，会把未保存的表单改动静默抹掉
- 位置：`lib/modules/organize/organize_page.dart:345`（`_openQueue`）、`:2199`（`_batchTagRedo`）、`:2208`（`_batchAddFolder`）、`:2270`（`_batchConfirm`）
- 现象/后果：`_openQueue` 是同步方法，不调 `_saveCurrent()`；而队列里的跳转（`_jumpToQuestion` :398）与改排序（`_applyQueueSort` :413）都先保存当前题。弹出层拿到的是打开时 `List.of(_queue)` 的快照，批量打标签 / 批量加文件夹 / 批量确认整理都用快照里的旧 `Question` 做 `repo.save(q.copyWith(...))` 整行覆盖。随后 `_closeQueue` → `_refresh` → `_loadForm` 从库重读，表单里未保存的改动（文件夹、标签、答案、错因等）全部消失，无提示。用户以为“切到别的题才自动保存”的承诺也覆盖队列操作，实际丢改动；批量确认整理还会把题按旧文件夹归档。
- 证据：复现——整理页改了当前题的文件夹或标签（别点保存/确认）→ 点“队列” → 勾上这道题 → “批量加入该文件夹”或“批量打标签 #需重做”或“批量确认整理” → 关队列回来，刚才在表单里的改动没了。
- 修的方向：`_openQueue` 改成异步，先 `await _saveCurrent()` 再弹层（与 `_jumpToQuestion` / `_applyQueueSort` 同款）；或让批量操作只改自己负责的字段时先重读最新行再合并。单删（`_deleteOne`）是显式删除，不受影响。

#### SR-P1-8 详情页“重新框选”：缩略图条按 `1..pageCount` 画，`pageCount` 恒为 1，源页 ≥2 的题点缩略图会切到一个不存在的“第 1 页”
- 位置：`lib/modules/detail/question_detail_page.dart:320-325`（`page: page, pageCount: 1`，`page` 是 `q.sourcePage`）；`lib/modules/collect/box_editor.dart:1533`（`for (var p = 1; p <= widget.pageCount; p++)`）、`:440-460`（`_switchPage`）
- 现象/后果：重框编辑器只有一页底图（`pageImagePath` 就是该题所在页），但底部缩略图条仍按 `pageCount` 画出“第 1 页”。若该题来自 PDF 第 2 页及以后（`sourcePage ≥ 2`），`_currentPage` 初始是 2/3，点一下唯一的缩略图就 `_switchPage(1)`：`_boxesByPage[1]` 不存在，画布上的框全消失（底图仍是原页图，因为 `_currentPageImagePath` 回退到 `pageImagePath`，更具迷惑性）；此时再画的新框进 `boxesByPage[1]`，确认时详情页只读 `result.boxesByPage[sourcePage]`，新画的框被无声丢弃；若直接点确认，`newLayer1` 仍是原页的框，倒不会丢数据，但用户会以为框丢了。
- 证据：复现——PDF 第 2 页及以后的题 → 详情页“重新框选这道题” → 点底部唯一的“第 1 页”缩略图 → 框消失；再画框、确认，新框不生效。
- 修的方向：重框模式下缩略图条只显示当前页一格（或直接隐藏整条 `_thumbStrip`，`pageCount == 1` 时不画切换条）；`_switchPage` 在 `pageCount == 1` 时拒绝切换到非当前页。顺带修文案：缩略图下标应显示真实页码（`sourcePage`）而非 1。

### 错题本 / 复习 / 报告 / 首页（SR-P1-9～SR-P1-13）

#### SR-P1-9 复习会话“上次自查”显示的是最早一次自查，不是最近一次
- 位置：`lib/modules/review/review_page.dart:1482`；数据源 `lib/data/db_questions.dart:140-144`
- 现象/后果：`_buildStepCause` 取 `history.last` 当“上次自查”。但 `reviewHistory()` 的 SQL 是 `orderBy: 'reviewed_at DESC'`（新→旧），`.last` 是最旧一条。用户在第 ① 步看到的“上次自查 · 日期·结果”会是第一次自查的记录，越练越错；补救文案、复查判断本身不受影响（只影响这一行展示）。
- 证据：`review_page.dart:1482` 的 `history.last` 对 `db_questions.dart:144` 的 `DESC`。同一数据源在别处无此误用（报告页只计数/过滤，与顺序无关）。
- 修的方向：改为 `history.first`（DESC 下首条即最新），或让 `_loadHistoryForSession` 明确按时间倒序取首条；加一测：同一题两条自查记录（旧“未解决”、新“已解决”），第 ① 步应显示新的那条。

#### SR-P1-10 学习报告薄弱 Top5 的计数按题名去重，同名不同题只算 1 道
- 位置：`lib/modules/report/report_page.dart:194`（`_causeGroups`）与 `:226`（`_kpGroups`）；`count` 定义见 `:173-175`（`titles.length`）
- 现象/后果：两处都用 `if (!g.titles.contains(q.title)) g.titles.add(q.title)` 去重，`count` 是去重后题名数，不是题数。题名并不唯一（如多道题都叫“第 1 题/选择题”），同名题会被合并计数，Top5 排序与“X 道题”文案都算错；`detail` 行用题名拼接，同名题也只显示一次。
- 证据：代码即证据。`_WeakGroup.titles` 是 `List<String>` 题名，未存题 id。
- 修的方向：`_WeakGroup` 改存题 id 集合（或 `List<String> questionIds`）做去重计数，`titles` 仅作展示；排序与 `countText` 以题 id 数为准。

#### SR-P1-11 学习报告的弱点 Top5 与学科分布把未整理题、已归档题也算进去了，与错题本口径不一致
- 位置：`lib/modules/report/report_page.dart:132`（`_load` 用 `repo.all(includeArchived: true)`）、`:169-172`（`_questionsInRange` 只按 `createdAt` 过滤）、`:179-238`（`_causeGroups` / `_kpGroups`）、`:303-306` 与文末 `_distRow` 循环
- 现象/后果：报告的弱点分组与“错在哪个学科 · X 道错题”分布统计的是“所选范围内收集的全部题”，含未整理（还在整理工作台排队、未进错题本）与已归档的题。错题本只收已整理未归档题（`wrongbook_page.dart` `_filteredAll`），封面题数、目录计数亦同口径。于是同一科同一时段，报告分布数会大于错题本题数；弱点 Top5 可能由尚未整理、甚至已归档的题顶上去，点行进错题本后列表里找不到这些题。
- 证据：`_questionsInRange` 无 `isOrganized / !isArchived` 过滤；`_causeGroups`、`_kpGroups`、`_distRow` 均直接消费 `qsIn`。
- 修的方向：`_questionsInRange` 增加 `q.isOrganized && !q.isArchived` 过滤（与错题本收录口径一致）；若 HTML `qsIn` 原意确含未整理题，需 Meng 裁决并把该口径写进报告页注释，而不是现状无注释。

#### SR-P1-12 错题本的排序与每页条数、复习的每页条数，在每次 `_load()` 后都被重置回设置默认值
- 位置：`lib/modules/wrongbook/wrongbook_page.dart:171`（`_pageSize = settings.pageSize`）、`:179`（`_sort = settings.wrongbookSort`）；`lib/modules/review/review_page.dart:283`（`_pageSize = settings.pageSize`）
- 现象/后果：用户在列表页把排序改成“时间旧→新”或把每页改成 20 后，只要进一次详情再回来、点一次星、做一次批量操作（错题本 `_load()` 有 19 处调用），排序/页数就跳回设置默认值。视图模式（大卡片/紧凑列表）已在 B2 用 `_viewModeInitialized` 标志修掉同类问题，但 `_sort` / `_pageSize` 被该文档明确写为“仍每次跟随设置（不在本次范围，未动）”，问题至今活着。复习页更甚：字段注释（`review_page.dart:147-149`）写着“只在打开时从设置默认值读一次初值”，代码却在每次 `_load()` 无条件覆盖，与注释直接矛盾；会话结束、暂停回列表都会重置页数。
- 证据：代码即证据；`_load()` 内 `_viewMode` 有 `if (!_viewModeInitialized)` 保护（`wrongbook_page.dart:174-177`），而 `_pageSize` / `_sort` 两行在其外、无保护。
- 修的方向：与 `_viewModeInitialized` 同款：排序与页数也只在首次 `_load()` 取设置默认值，之后保留页内选择；或把“页内改动是否写回设置”由 Meng 定（现复习页注释称“下拉改动不写库、不改设置默认值”，与“每次 `_load` 覆盖”合起来等于页内改动随时丢失）。修后补测：改排序/页数 → 进详情返回 → 仍保留。

#### SR-P1-13 复习会话里跳过一题的最后一个错因，会把上一个已写完补救的错因重新呈现一遍
- 位置：`lib/modules/review/review_page.dart:571-603`（`_skipCurrent`）
- 现象/后果：设一题有错因 A、B、C，用户已依次写完 A、B 的补救，`_ci = 2`（C）时点“跳过”：`removeAt(2)` 后块剩 [A, B]，`_ci >= length` 触发 `_ci = length - 1 = 1`，`_phase` 回到 `recall`，于是 B 被重新呈现（补救输入框已清空——内容已存库，未丢，但用户须多点一次“下一步”才能进重做）。按模型，A、B 既已走完，第 ①② 步应结束、直接进第 ③ 步重做；跳过 C 不应倒退。
- 证据：`review_page.dart:592-599` 的分支逻辑；`_nextFromRemedy`（`:605-620`）是 `_ci < length - 1` 才前进、否则进 `redo`，`_skipCurrent` 未复用该收尾判断。
- 修的方向：跳过后若 `_ci` 已越过块尾（即剩余错因全部已走完 ①② 步），直接进 `_Phase.redo` 而不是把 `_ci` 钳回 `length - 1`；只有块中部跳过时才停在当前 `_ci`（下一个未走完的错因自动顶上来）。加一测：三错因题，前两个走完、跳过第三个，应直接出现重做步。

### 服务层（SR-P1-14～SR-P1-17）

#### SR-P1-14 图片 20MB 上限只提示不执行；超限横幅文案与 PDF 硬失败自相矛盾
- 位置：`lib/services/import_service.dart:145-157`（`oversizeHint`）、`enqueue` 内 PDF 50MB 硬判（约 :209-224）、图片分支无任何尺寸硬判；`lib/modules/collect/collect_page.dart:766-771`（横幅）
- 现象/后果：`maxImageBytes`（20MB）在全仓库只被 `oversizeHint` 用到一次；`enqueue` 里 PDF 超 50MB 会直接进 `failed` 任务，图片超 20MB 没有任何拦截，照常复制、归一化、进 `needBox`。“图片限 20MB”这条决定实际未执行。收集页横幅标题写的是“文件超过大小上限，只是提示，不直接判失败”，文案是“仍可继续导入”。对 PDF 这是假话：用户点“仍然再导一份”后 `enqueue` 仍会把 >50MB 的 PDF 判失败，横幅承诺落空；对图片则是另一方向的假话：根本没有上限可言。
- 证据：代码即证据；超大图片悄悄入库（检测更慢、多占 2GB 预算）。
- 修的方向：二选一并统一文案——(a) `enqueue` 对图片也硬判 20MB，横幅按 PDF/图片区分说法；或 (b) PDF 也改回只提示（与 §6 第 3 条“限 50MB”冲突，不建议）。建议 (a)。

#### SR-P1-15 `CompactSliceThumb` 的 `Image.file` 没有 `errorBuilder`，损坏切片无失败占位
- 位置：`lib/widgets/widgets.dart:609`（`Image.file(sliceFile, fit: BoxFit.cover, cacheWidth: 128)`，无 `errorBuilder`）；对照 `:393-400`（`QuestionSlice` 的同一位置有 `errorBuilder`，走 `_missingImagePlaceholder`）
- 现象/后果：紧凑列表里切片文件存在但内容损坏/解码失败时，`Image.file` 不显示“加载失败/图片缺失”占位，只剩空白框或框架错误日志；`failed`/`missingRealImage` 两条占位分支都走不到（文件存在，`existsSync` 为真）。错题本紧凑视图出现空白缩略图，用户无法区分“没图”和“图坏了”，与大卡片行为不一致。B3 汇总遗留点 4，属实（收集组与服务层组各自独立核实一致）。
- 修的方向：给 `:609` 的 `Image.file` 补 `errorBuilder`，复用 `:563-600` 失败分支的同一占位（学科图标 + “加载失败”）。同款：`box_editor.dart:1352` 的页图 `Image.file` 也无 `errorBuilder`，但有 `_pageImageFailed` 门控（`_loadPageImageSize` 用同一文件解码先行判断），风险低得多，顺带补即可。

#### SR-P1-16 YOLO 模型首次加载失败后永久锁死，运行中补放模型文件也无法恢复
- 位置：`lib/services/yolo_onnx_service.dart:119,173-174`（`static bool _loadAttempted`；`if (_loadAttempted) return _loadOk;` 后 `_loadAttempted = true`）；唯一重置点是 `@visibleForTesting resetLoadStateForTest`（:106）
- 现象/后果：`_ensureLoaded` 失败一次后 `_loadAttempted` 恒为真，之后每次 `detectPage` 都直接返回“自动检测不可用，请手动框选”，不再尝试加载。Meng 在应用运行中把模型文件放进 `assets/models/question/`（或首次是权限/路径问题）后，必须重启应用才生效。与“模型文件 Meng 自己放”的工作流直接摩擦；用户看到的是一直不可用的检测，没有任何“重试”入口。
- 修的方向：加载失败时不锁死 `_loadAttempted`（或失败后按调用次数/时间间隔重试，如每 N 次检测重试一次）；至少在 `detectPage` 的 fallback 路径上允许下一次调用重走 `_ensureLoaded`。

#### SR-P1-17 `ImportService.enqueue` 的重复判断是空分支；同批两次选同一文件会静默建两个任务
- 位置：`lib/services/import_service.dart:185,195-200`（`final duplicate = existing.any(...)`，随后 `if (duplicate) { /* 只有注释 */ }`）；`lib/modules/collect/collect_page.dart:180-194`（重复判断只查已入库的 `_tasks`）
- 现象/后果：服务层算出了 `duplicate` 却没有任何行为：不拦、不标记、不返回，任务照常创建。重复提示完全依赖收集页自己的 `_tasks` 快照，`enqueue` 被其他调用方复用时无任何去重。同批内重复也查不到：收集页只拿本次选中的路径与已入库任务比对，同一文件在一次多选里出现两次时，两次都不在 `_tasks` 里，横幅不弹，直接建两个重复任务；服务层的 `existing` 快照同样不含本批刚建的任务。后果：重复任务、重复切片、重复占 2GB 预算；用户要手动删。
- 修的方向：把去重收进 `enqueue`：快照改为边建边更新（含本批已建任务），重复文件直接跳过或返回带 `duplicate: true` 的结果给调用方弹“已经导入过”；`duplicate` 变量要么生效要么删除。

### 文档（SR-P1-18～SR-P1-39，均为模块边界文档 / decision-log / CODEBUDDY / 代码地图 / 四方分工与代码现状不符）

#### SR-P1-18 边界文档 §4.3：整理表单字段顺序与必填项仍是旧版
- 位置：`docs/quiz-master2-mo-kuai-bian-jie-hua-fen.md` §4.3“整理表单（F 分段折叠式）：字段顺序固定为学科、文件夹、试卷、知识点、错误类型、标签、答案、解析、备注；只有学科与文件夹必填”
- 现状：学科字段已在整理页删除（2026-11-12 决定）；只有文件夹是必填；实际分段是修框切片 / 文件夹（归类）/ 来源（可选）/ 分类补充（可选）/ 答案 · 解析 · 笔记（可选），没有“备注”字段（是“笔记”）。证据：`lib/modules/organize/organize_page.dart:18`，分段标题 `:762`、`:1061-1063`、`:1070-1071`、`:1079-1080`、`:1088-1090`；必填校验只看文件夹 `:1102`、`:2135-2136`。
- 修的方向：按 D-08 与整理页现状重写该段：删“学科”字段，必填只写文件夹，分段与字段名按五段现状写；“备注”改“笔记”。

#### SR-P1-19 边界文档 §4.3：整理工作台仍写“固定高度的盒子，滚动只发生在盒内”
- 位置：同上 §4.3“待整理队列：整个工作台是一个固定高度的盒子，队列、整题图、表单都在盒内，滚动只发生在盒内”
- 现状：D-08 已定布局 H——无固定高度容器、整页滚动；队列不常驻，藏在左上角“队列”按钮后的弹出层里。证据：`organize_page.dart:534,606,623` 均为 `SingleChildScrollView` 整页滚动；队列是 `OverlayEntry` 弹出层（`_QueuePopup`，`:344`）。
- 修的方向：改写为 D-08 口径：左图右表、整页滚动、队列为弹出层；删“固定高度盒子、盒内滚动”。

#### SR-P1-20 边界文档 §4.3：队列行“待补充只统计必填项（学科与文件夹）”
- 位置：同上 §4.3“队列行信息：每行显示标题、学科、试卷来源与待补充数量，待补充只统计必填项（学科与文件夹）”
- 现状：必填只有文件夹，待补充只数文件夹一项；学科不是必填项。证据：`organize_page.dart:1102`、`2135`（`missing = q.folderIds.isEmpty ? '待补充 1 项：文件夹（归类）' : '必填已齐'`）。
- 修的方向：改为“待补充只统计文件夹（唯一必填项）”。与 SR-P1-18 同根，可合并修。

#### SR-P1-21 边界文档 §4.2：导入学科“默认上次所选学科”（两处）
- 位置：同上 §4.2“导入时选学科：导入框上方一条紧凑的单行学科下拉，默认上次所选学科”；以及“进：从左侧导航或首页快速收集进入；可带预选学科 ID，没有则用上次所选学科作默认”
- 现状：D-15 已定导入学科每次都选，默认“请选择学科”，不默认上次/数学，不选不能导。证据：`lib/modules/collect/collect_page.dart:28`、`:96`、`:940` hint `'请选择学科'`。
- 修的方向：两处都改为“默认‘请选择学科’，每次导入必选”；预选学科 ID 的说法若代码不支持则删。

#### SR-P1-22 边界文档 §4.2：“取消导入中途的任务停留在修框中状态”
- 位置：同上 §4.2“任务列表：……导入可取消，导入队列在应用重启后保留”一段中“取消导入中途的任务停留在修框中状态”
- 现状：取消导入 / 取消排队是直接删除任务，无二次确认，任务不保留、不停留在修框中。证据：`collect_page.dart:664-669`“取消导入 / 取消排队：直接删，无二次确认”，`_removeTask` 直接调 `deleteCollectTask`；按钮在 `:1244-1252`。
- 修的方向：改为“取消导入 / 取消排队直接删除该任务（不弹确认）”；失败任务的删除走模态确认（B3 已改，见 `:677` 起 `_deleteTask`）。

#### SR-P1-23 边界文档 §4.2：“确认后拆成多个任务，原任务不保留”——缺 P1-2 例外
- 位置：同上 §4.2“多页与多题：……确认后拆成多个任务，原任务不保留”
- 现状：P1-2 已定——多页 PDF 有未框页时，确认只拆有框页，没框的页留在任务里，原任务按同 id 重建回“待框选”，从首个未框页继续。证据：`collect_page.dart:426-428`、`:576-600`；确认前弹框 `:460-463`。
- 修的方向：补 P1-2 例外：原任务一般不保留，但有未框页时按同 id 重建保留。

#### SR-P1-24 边界文档 §4.2：“已整理完成的任务归档，不再出现在列表中”
- 位置：同上 §4.2“任务列表：……已整理完成的任务归档，不再出现在列表中”
- 现状：已整理（`done`）任务仍在任务列表中展示，行上有“删除”按钮（走模态确认）。证据：`collect_page.dart:151` `_tasks = tasks`（不过滤 `done`）；`:1306-1313` `CollectStatus.done` 行仍有“删除”按钮（走 `_deleteTask`）；`:640` 亦把 `done` 计为已拆页来源。
- 修的方向：改为“已整理完成的任务仍留在列表中（可删除），不自动归档/隐藏”；若产品上希望隐藏，需另立决定再改代码。

#### SR-P1-25 边界文档 §4.4：错题本筛选“含文件夹”
- 位置：同上 §4.4“书内工具栏：搜索框在列表上方；筛选为折叠式面板，含文件夹、试卷、错误类型、时间、复习状态、标签、仅收藏、仅逾期、已归档等条件”
- 现状：筛选面板没有文件夹筛选——文件夹在目录页选（D-12、代码地图均已写明“筛选里没有文件夹”）。证据：`lib/modules/wrongbook/wrongbook_list.dart:190-390` 筛选面板单元格只有试卷（来源）/ 错误类型 / 收集时间 / 错因状态四项下拉 + 标签行 + “只看”行（仅收藏 / 仅逾期 / 已归档），无文件夹项。
- 修的方向：删“文件夹”；补写知识点筛选（报告/错因跳转带入的 `_filterKpIds`）与错因筛选（`_filterCauseName`）的存在形式。

#### SR-P1-26 边界文档 §4.4：大卡片描述与实现完全不符
- 位置：同上 §4.4“大卡片（默认视图）：一道题占一行、整行一张卡，整题图占整整一行并占满卡片宽度，图片下方依次是相关信息——题名、学科、错误类型、标签、下次复习时间（含逾期与今天到期标记）与收藏星，不显示文件夹与复习状态”
- 现状：实际大卡片只有整题切片图 + 左上角蓝色序号圆盘，卡片上不显示题名 / 学科 / 错误类型 / 标签 / 下次复习时间 / 收藏星；题名等信息只在紧凑列表行里。证据：`wrongbook_list.dart:720-724` 注释“卡片上不显示题名 / 学科 / 错误类型 / 标签 / 下次复习时间 / 收藏星”；`_buildLargeCard`（`:726` 起）只渲染 `QuestionSlice` + 序号圆盘（批量模式下另有复选框）。
- 修的方向：按代码重写大卡片段：切片独占一行、序号圆盘、无文字信息；“下次复查 / 错因 pill / 收藏星”移至紧凑列表段描述。

#### SR-P1-27 边界文档 §5.1：题目详情仍标“未确认”，待确认点全部已定
- 位置：同上 §3 总览表“题目详情 /question/:id 未确认”；§5.1“待确认点：字段排布与分区方式、哪些字段可编辑及编辑控件形态、删除与归档入口是否放在本页、是否需要上一题 / 下一题切换、从本页发起单题复习的入口是否需要”
- 现状：详情页已于 2026-11-12 由 D-13 定稿并实现——方案 2 分段折叠式（答案解析 / 题目信息 / 复习记录三段默认全折起）、编辑模式保存生效、学科不可改、删除/归档在页内、上一题/下一题按来源列表顺序、无“开始复习”按钮（只有加入/取消加入复习）。证据：`lib/modules/detail/question_detail_page.dart:10-16` 文件头注释逐条写明上述定稿；`:1018` 三段折叠；`:1758-1807` 底部操作行。
- 修的方向：§5.1 移入 §4 已确认节（或改为“已确认”，内容按 D-13 重写）；§3 计数同步修正（见 SR-P2-82）。

#### SR-P1-28 边界文档 §5.2：学习报告“薄弱点 Top 5 与按试卷分布尚未确认；统计口径、时间范围与呈现形式均待定”
- 位置：同上 §5.2“待确认点：薄弱点 Top 5 与按试卷分布两项提案尚未确认；统计口径、时间范围与呈现形式均待本页详细设计时定”；以及“出：如需从统计跳到题目范围，凭学科 ID 去错题本打开对应一本，是否需要此跳转待确认”
- 现状：报告已由 D-14（2026-11-12）定稿并实现——弱点 Top 5 按错因与知识点各一组、按关联题数排、“看更多”展开全部；分布只按学科、不按试卷；时间范围本周 / 本月 / 全部（默认本周）；核心数只三项；点弱点打开错题本按该错因/知识点过滤。证据：`lib/modules/report/report_page.dart:122-124`、`:304-308`、`:609-611`、`:749`；D-14 原文与之一致。
- 修的方向：§5.2 改为已确认节，按 D-14 重写；“按试卷分布”提案明确写“已否决（只按学科）”。

#### SR-P1-29 边界文档 §5.3：文件夹与自定义错因“都在此（学科管理）维护”
- 位置：同上 §5.3“基础字典维护：文件夹（自由建立、可含子文件夹）、标签、自定义错误类型的定义都在此维护，供整理工作台选用”
- 现状：文件夹不在学科管理里——只在错题本目录页增删改/移动/排序/搜索；自定义错因没有全局定义——固定枚举 5 个 + 每题自带的自定义错因（只跟本题，下次可选，不进全局枚举）。证据：`lib/modules/subjects/subjects_page.dart:8-9` 文件头“无文件夹段（文件夹只在错题本目录页管）”，四段为学科 / 知识点树 / 标签 / 试卷；`lib/models/models.dart` `ErrorTypes` 固定枚举 + `customErrorTypes` 每题字段；代码地图 §3 同样写明。
- 修的方向：删“文件夹”与“自定义错误类型的定义”；改为“学科管理只维护学科、知识点树、标签、试卷；文件夹归错题本目录页；自定义错因随题保存”。

#### SR-P1-30 边界文档 §5.3：学科删除与设置清单“均待确认”
- 位置：同上 §5.3“待确认点：两页的详细设计尚未开始；学科删除时其下已有题目的处理方式、知识点树的编辑粒度（增删改的层级限制）、文件夹与标签的合并或重命名规则、设置项的完整清单，均待确认”
- 现状：学科删除已实现——删学科会删掉其中全部题与该科文件夹，模态弹窗确认（含题数与后果文案）；设置项已由 D-11 定为五组折叠（外观 / 复习 / 错题本 / 数据 / 启动与关于）。证据：`lib/modules/subjects/subjects_page.dart:644` 删除学科确认文案；D-11；`lib/modules/settings/settings_page.dart` 五组结构。
- 修的方向：该待确认点改为已定事项逐条写清；仅保留真正未定的子项（如有），否则整段删。

#### SR-P1-31 边界文档 §2：数据层仍写“复习状态与下次复习时间的唯一存放处”
- 位置：同上 §2“数据层：题目、学科、文件夹、标签、试卷、知识点树、错误类型、复习状态与下次复习时间的唯一存放处”
- 现状：旧复习字段（`review_status` / `next_review` / `overdue_days`，1/3/7/14 口径）已废弃删除；复习数据现存于 `cause_records`（错因 + 状态 + 解决次数 + 复查日）/`review_state`（会话断点）/`review_history`（自查历史）。证据：D-05；`lib/data/database.dart:95-96` 注释；`lib/data/db_schema.dart:147-166` 三张复习相关表。
- 修的方向：改为“……错误类型、错因解决记录与复查日、自查历史、复习会话断点的唯一存放处”。

#### SR-P1-32 边界文档 §4.1：“卡片内的继续按钮进整理工作台”
- 位置：同上 §4.1“今日到期焦点大卡片（C 焦点大卡片版式）：……卡片内的继续按钮进整理工作台，两者互不误触”
- 现状：焦点卡内的“继续上次”按最近任务的 kind 跳转——整理去整理工作台，收集去收集中心，其他（复习）去复习页；不是固定进整理工作台。证据：`lib/modules/home/home_page.dart:166-176` `_resumeRecent`（`organize`→整理、`collect`→收集、默认→复习）。
- 修的方向：改为“卡片内的‘继续上次’按最近任务种类回到原进度（整理/收集/复习三处）”。

#### SR-P1-33 decision-log D-07：已被 D-23 取代，却未标注作废
- 位置：`docs/decision-log.md` D-07“YOLO 与 onnxruntime（待 Win11 测试）”：“先用占位服务（一页一个整题框 + 两层框 + 钳制），真实 `best.onnx` 由用户后续提供；onnxruntime 的 Dart 包版本不 pin”
- 现状：D-23（2026-11-13）已推翻其中三点——第 1 层已接真模型（`onnxruntime ^1.4.1` 已 pin）、第 2 层暂缓（不再是“两层固定”）、占位只作模型缺失/加载失败时的回退。D-07 未标注“已被 D-23 取代”，按 D-07 行事会拆掉真模型接入。证据：`pubspec.yaml`（`onnxruntime: ^1.4.1`）；`lib/services/yolo_onnx_service.dart:67`（`intraEnabled = false`）、`:99`（`hasRealModel`）。
- 修的方向：在 D-07 标题与正文首行加“已被 D-23 取代（2026-11-13），仅留作历史；占位服务现仅为回退路径”。

#### SR-P1-34 decision-log D-04：演示数据未注明“新库从空开始、不预置”
- 位置：`docs/decision-log.md` D-04“演示数据（已确认，v1 D-11 沿用）：数学 / 英语 / 政治各 3 道大学题，`is_demo = 1`；‘清空演示数据’只删演示题。设置页有该入口”
- 现状：§6 第 1 条已定新库从空开始、不预置演示题——`demoQuestions()` 只有定义、没有任何生产调用方，`_seed` 只播种学科/文件夹/标签/试卷/知识点树与 `schemaVersion`，新库演示题数为 0；“清空演示数据”入口仍在，但对新库无事可做。证据：`lib/data/db_schema.dart:230-283` `_seed`；`lib/data/demo_data.dart:5` `demoQuestions()`；全仓 grep 仅定义一处，无生产调用。
- 修的方向：D-04 补注“§6 第 1 条（2026-11-13/14）：新库建库时不预置演示题；`demoQuestions()` 仅作定义保留，演示库 v1 仍是 9 道题的老库”。

#### SR-P1-35 decision-log D-06：“继续上次优先级复习 > 整理 > 收集”未实现，需 Meng 定方向
- 位置：`docs/decision-log.md` D-06（首页计数口径）所涉“继续上次”优先级（同款表述亦见边界文档 §4.1“继续上次：……三者同时存在时优先级为复习高于整理、整理高于收集”）
- 现状：`recent_tasks` 是只有 id=1 一行的单行表，`saveRecentTask` 是纯 REPLACE 后写优先，无任何三方比较逻辑；同时存在三类未完成任务时，胜出的是最后一次保存的那一个，不是按复习 > 整理 > 收集排优先级。证据：`lib/data/db_settings.dart:89-101` `saveRecentTask`（`ConflictAlgorithm.replace`，无优先级比较）；`lib/modules/home/home_page.dart:166-176` `_resumeRecent` 只按存下的 kind 跳转。**注：错题本组“干净清单”称“继续上次优先级与中英文 kind 双认完整”，指的是 `_resumeRecent` 按 kind 跳转的路由本身无问题，与本条（多任务并存时谁胜出无优先级比较）并不矛盾。**
- 修的方向：二选一并记入日志——(a) 承认现状为“最后一次活动优先”，删优先级规则；(b) 若要保留规则，需改 `saveRecentTask` 在写入时按优先级比较（改动需 Meng 定）。在决定前，D-06 与 §4.1 的优先级句应标注“未实现”。

#### SR-P1-36 四方分工：基线代码 head 与测试数过期
- 位置：`docs/四方分工.md` 首行“基线：GPT 对话‘项目现状同步’（2026-11-14），代码 `ui-replication` 分支 head `afb68e3`，全量测试 537 通过”
- 现状：本工作树 `git log --all` 中不存在 `afb68e3`（可查到的提交头为 `bca8586`）；全量测试在 Batch 3 结束时已是 628/628（Batch 1 结束 560、Batch 3 结束 628），537 是更早的基线数。**协调员注：`afb68e3` 是远端 `ui-replication` 的 head（2026-11-14 08:44 推送）；快照推送不写本地 git 历史，本地 log 查不到属正常，不是“哈希编造”。文档应注明这是远端 head，或去掉具体哈希。**
- 修的方向：基线改为“head `bca8586`（本地）/ 远端 `afb68e3`（以远端为准），全量测试 628/628（Batch 3/4 后，未提交未推）”，并注明基线日期；或删具体哈希/测试数，改为“以 B4-SUMMARY 为准”。

#### SR-P1-37 CODEBUDDY.md：“当前状态”未提 Batch 4 拆分
- 位置：`docs/CODEBUDDY.md`“当前状态（2026-11-14）”：“Batch 1/2/3 的改动在工作树里，未提交、未推送”
- 现状：Batch 4（God 类拆分）同样已完成、未提交、未推送，且改变了文件结构——`database.dart` 3191→541 行 + 10 个 `db_*.dart` part 文件；`collect_page.dart` 3349→1316 行 + `box_editor.dart`；`wrongbook_page.dart` 3718→1141 行 + 5 个 `wrongbook_*.dart`。按 CODEBUDDY 现状行事会找不到实现位置。证据：`lib/data/database.dart:14-25`（10 个 `part` 声明）；`lib/modules/wrongbook/wrongbook_page.dart:9-13`；`docs/ui-replication/B4-SUMMARY.md`。
- 修的方向：补 Batch 4 一节（拆分清单、纯重构性质、入口文件与 part 文件对照、测试仍 628/628）。

#### SR-P1-38 代码地图：头注称“最终验证还没跑”，与 B3/B4 已完成的验证矛盾
- 位置：`docs/代码地图.md` 头注“仓库里仍有 Batch 1/2/3 未提交的改动（分支 `ui-replication`，本地 head `bca8586`……）；最终验证还没跑，本文中不写死全量测试通过数”
- 现状：B3 与 B4 均已由协调员跑过最终统一验证——`flutter analyze` 0 问题、全量测试 628/628、Linux Release 构建成功、演示库 md5 未变（`8f7f9c64…`）。证据：`docs/ui-replication/B3-SUMMARY.md`“最终验证”、`B4-SUMMARY.md`“协调员最终统一验证”。
- 修的方向：头注改为“Batch 1/2/3/4 已完成、未提交未推；最终验证已跑（analyze 0 问题、测试 628/628、Linux 构建成功），结论见 B3/B4-SUMMARY”。

#### SR-P1-39 代码地图 §2/§3/§6：B4 拆分后文件引用过期
- 位置：`docs/代码地图.md` §2“9 个页面，每页一个文件，一个文件就是一个模块”及文件表（`lib/data/database.dart` 单文件、`lib/modules/collect/collect_page.dart` 单文件、`lib/modules/wrongbook/wrongbook_page.dart` 单文件）；§3“13 张表（`database.dart` 的 `createTables` 里建表）”；§6“`lib/data/database.dart` 的 `createTables` 里改建表语句”
- 现状：B4 后 `database.dart` 只剩 541 行入口，建表在 `lib/data/db_schema.dart`（`createTablesImpl`，`:98`）；`collect_page.dart` 拆为 3 文件（修框编辑器在 `box_editor.dart`，2021 行）；`wrongbook_page.dart` 拆为 6 文件（part 机制）。证据：`wc -l`：`database.dart` 541、`db_schema.dart` 279、`collect_page.dart` 1316、`box_editor.dart` 2021、`wrongbook_page.dart` 1147、`wrongbook_list.dart` 1142 等；`lib/data/database.dart:14-25` part 声明。
- 修的方向：§2 文件表按 B4 结构重写（入口 + part 文件清单及职责）；§3/§6 的 `database.dart createTables` 改为 `db_schema.dart createTablesImpl`。

## P2（92 项）

### 数据层（SR-P2-1～SR-P2-17）

#### SR-P2-1 删学科漏清草稿框：`deleteSubjectFrom` 不删该科任务的 `question_boxes` 草稿行
- 位置：`lib/data/db_catalog.dart:17-52`
- 现象：事务内删题（经 `_deleteQuestionTxn`，只清 `question_id` 指向该题的框）→ 删 `collect_tasks` → 删 `recent_tasks`/`folders`/`knowledge_points`/`subjects`，但从不删 `collect_task_id` 属于这些任务、`question_id IS NULL` 的草稿框（含其 layer-2 子框）。删学科后库里永久残留指向已删任务的孤儿框行。行本身不再被任何查询读到（`boxesForTask` 按任务 id 查，任务已删），属惰性膨胀 + 违反“删学科清干净”的预期；若将来按 `collect_task_id` 做统计/清理会踩到。
- 修的方向：事务内先按该科任务 id 集合删 `question_boxes where collect_task_id IN (...)`（或在删 `collect_tasks` 前对每任务调已有逻辑），补单测：建学科 + 任务 + 草稿框 → 删学科 → `question_boxes` 为空。

#### SR-P2-2 清演示数据绕开删题事务：`clearDemoDataFrom` 不清框、不置空任务指向、还全清 `recent_tasks`
- 位置：`lib/data/db_settings.dart:19-54`
- 现象：事务内只删演示题的 `cause_records`/`review_history`、整行 `review_state`、**全部** `recent_tasks`、演示题行。缺三样：(a) 不删演示题的 `question_boxes`（与 `_deleteQuestionTxn` 不一致）；(b) 不把 `collect_tasks.question_id` 指向演示题的行置空，留下悬空指向；(c) `recent_tasks` 只有 id=1 一行，清掉它会连非演示的“最近任务”一起抹掉，与注释“非演示数据一律不动”矛盾。现实中演示题通常没有框/任务（`_seed` 不预置演示题，`db_schema.dart:230` 起），所以实际影响小，但这是三处删题入口中唯一不走 `_deleteQuestionTxn` 的。
- 修的方向：复用 `_deleteQuestionTxn` 删演示题（或至少补删其框、置空任务指向）；`recent_tasks` 只清指向演示题的行（或不动它）。

#### SR-P2-3 详情页重框：新切片先写盘，事务失败残留孤儿切片（B3 遗留点 6，属实）
- 位置：`lib/modules/detail/question_detail_page.dart:347-366`（`writeAsBytes` 在 `:354`，`replaceQuestionBoxesAndSlice` 在 `:366`）；`lib/data/db_collect.dart:298-324`（事务本身没问题）
- 现象：切片文件在事务前写盘；事务因题不存在（`updated != 1` 抛错，`db_collect.dart:318-320`）或其它 DB 错回滚时，新切片文件已落盘、无任何行引用。无数据不一致，只有孤儿文件，孤儿清理可回收。
- 修的方向：事务失败时调用方删刚写的切片文件；或先写临时名、事务成功后再改名。低优先级。

#### SR-P2-4 备份校验有缺口：缺表按空表静默清空、主键可为 null、不校验必填列
- 位置：`lib/data/db_backup.dart:35-80`（`validateBackupDataImpl`）、`:103-141`（`importBackupJsonIntoImpl`）
- 现象：(a) `validateBackupDataImpl` 只强制 `subjects`/`questions` 为数组，其它表键缺失时 `rows == null → continue`，而恢复是“清表再插回”——一份缺了 `cause_records` 的备份恢复后会**静默清空全部错因记录**，用户无从察觉；(b) 只查 `row.containsKey('id')`，`id: null` 也能通过，插库时才抛 NOT NULL 错误；(c) 不校验必填列/类型（如 `questions` 缺 `title`/`subject_id`），非法行在恢复事务中途才抛原生 `DatabaseException`，而不是 `BackupRestoreException`，设置页展示的是原始 sqlite 文案。事务本身保证了“要么全进要么全不进”，所以是“校验不充分 + 报错不友好”，不是半截库。
- 修的方向：校验层补三条：全部 13 张表键缺失即拒绝（或明确提示缺表按空处理并让用户确认）；`id`/`key` 非空；每表必填列存在且类型正确。插库异常统一包成 `BackupRestoreException`。

#### SR-P2-5 备份恢复绕过 2GB 存储上限；zip 导入上限是 4GB 不是 2GB
- 位置：`lib/data/db_backup.dart:185`（`readZip` 默认 `maxTotalBytes = 4GB`）、`:217-297`（`importBackupZipIntoImpl` 全程无容量检查）；对照 `lib/services/import_service.dart:40-41,218-227,355-366`（2GB 上限只在 `enqueue` 导入路径执行）
- 现象：§6 第 9 条定的 2GB 上限只在“导入文件”时拦。恢复一个 3GB 的 zip 备份会直接把库撑过 2GB，无任何提示；恢复 JSON 备份同理。与既定决定不一致。
- 修的方向：`importBackupZipIntoImpl` 在文件进位前估算（现有占用 − 将被覆盖的文件 + 解压后总字节），超 2GB 拒绝整个恢复；或至少在恢复成功后提示已超上限。

#### SR-P2-6 zip 恢复：DB 失败时错误文案误导；旧 staging 清理不校验时间戳
- 位置：`lib/data/db_backup.dart:240-297`
- 现象：(a) catch 里一律包成“恢复失败：文件写不进去，原题库没动”——但 `importBackupJsonInto` 抛出的 DB 错误（如 SR-P2-4 的非法行）也会走这条文案，用户会被误导去查磁盘而不是备份文件内容；(b) 开头的旧 staging 清理只认前缀 `.restore-staging-`（`:248`），不像迁移的 `_deleteStaleMigrationStaging`（`db_storage.dart:233-249`）那样校验纯数字时间戳，数据目录下一个同名用户目录会被误删。两处都是小口径。
- 修的方向：区分 `BackupRestoreException`（原样抛）与 DB 异常（文案写“备份数据有问题”）；staging 清理复用 B2-5d 的严格匹配。

#### SR-P2-7 `setCustomDataDirectory` 忽略测试隔离钩子，且先写标记文件后写设置
- 位置：`lib/data/db_paths.dart:130-137`；对照 `lib/data/db_storage.dart:319`（`migrateToDirectory` 用 `testMarkerDirectory ?? _defaultDataDirectoryPath()`）
- 现象：该方法直接写 `_defaultDataDirectoryPath()` 下的 `db_location.txt`，不认 `testMarkerDirectory`——测试调它会改真实标记文件（B3-P02 测试隔离的口子）；且先写标记、再 `saveSetting('databaseLocation', ...)`，后者失败时标记已换、下次启动就用新目录，与设置里记录的位置不一致；另对 `dir` 无任何校验（空串/不存在的路径照写，好在空串会被 `dataDirectoryPath` 的 `isNotEmpty` 兜住）。
- 修的方向：标记目录改为 `testMarkerDirectory ?? _defaultDataDirectoryPath()`；先校验目录可写、顺序改为先写设置后写标记（或失败时回滚标记）。

#### SR-P2-8 `setReviewJoined` / `syncCauseRecords` 多步写不在同一事务
- 位置：`lib/data/repository.dart:36-57`
- 现象：`setReviewJoined` 先 `upsertQuestion(reviewJoined: true)`，再 `ensureCauseRecords`（逐条 insert）；中间抛错/被杀，题已标“已加入复习”却没有一条 `cause_records`。`dueToday`（`repository.dart:66-80`）对无记录的题返回 false、`subjectCounts` 跳过它——题从复习计数里静默消失，用户以为已加入、实际永远排不到。`syncCauseRecords` 同样是“全表读 + 逐条删 + `ensureCauseRecords`”三段分离，中间失败会留下“旧错因记录已删、新错因记录未补”的半截状态。
- 修的方向：数据层加一个事务版（如 `setReviewJoinedInto(db, q, joined)`），题行 + 错因记录同事务；`syncCauseRecords` 同理。

#### SR-P2-9 `saveSettings` 逐条写设置，无事务
- 位置：`lib/data/db_settings.dart:137-141`（循环调 `saveSetting`，每次独立 insert）
- 现象：设置是相互独立的键，单条失败只影响该键，不丢题；但一次“保存全部设置”中途失败会留下新旧混杂的设置组合（如主题已换、字体未换）。影响小。
- 修的方向：包进一个 `db.transaction` 批量 replace。

#### SR-P2-10 `confirmSplitInto` 用 REPLACE 静默覆盖已存在的题/拆分任务
- 位置：`lib/data/db_collect.dart:382-430`（`txn.insert(..., ConflictAlgorithm.replace)`，题 `:394`、拆分任务 `:415`）
- 现象：若同 id 的题已存在且已整理（`is_organized=1`、已有解决记录），重复确认会把它覆盖回未整理的全新题，而旧的 `cause_records`/`review_history` 还挂在这个 id 上——已治愈的记录贴到了一道“新题”上。UI 层有 `_splitPagesFor` 防重复拆（`collect_page.dart:633` 起），所以正常流程走不到这里；但数据层没有任何防呆（与 `_deleteBoxesForQuestionTxn` 特意防“两个 layer=1 框”的谨慎不一致）。
- 修的方向：题与拆分任务改 `ConflictAlgorithm.fail`（或先查存在即抛错），让重复确认显式失败而不是静默覆盖。

#### SR-P2-11 `deleteLegacyDatabaseIfPresent` 主库删完、附属文件删失败才抛错
- 位置：`lib/data/db_schema.dart:51-89`（`:81-88` 先 `file.delete()`，再删 `-wal`/`-shm`，后者失败抛 `LegacyDatabaseException`）
- 现象：主库已删、抛错称“删除失败，下次启动重试”——下次启动文件已不存在，会直接建空库，所谓“重试”不存在；更糟的是残留的旧 `-wal` 会留在新库旁边（新库建在同一路径时，SQLite 按 salt 校验一般会忽略不匹配的 WAL，但属于“删一半留一半”的脏状态）。老库本来就是要整体删除的（§6 第 1 条，已定），所以不是误删数据，是错误处理与文案不一致。
- 修的方向：先删 `-wal`/`-shm` 再删主库；或附属文件删失败只记日志不抛错（主库已删即算删除成功）。

#### SR-P2-12 `newBoxId` 只有 32 位随机熵
- 位置：`lib/data/db_paths.dart:69-79`（8 位十六进制，`Random.secure()`）
- 现象：同一 `(scope, page)` 下 8 hex = 32 位，框数上千时碰撞概率进入可感知区间（生日悖论约 7 万个框 50%）；而 `saveDraftBoxesInto`、`_replaceBoxesTxn`、`confirmSplitInto` 插框全用 `REPLACE`——碰撞会静默覆盖另一道框，不报错。现实框量（每页个位数、每任务数十）下概率极低。
- 修的方向：随机部分扩到 12-16 位十六进制，或插框前查 id 是否已存在（存在则重生成）。

#### SR-P2-13 `demoQuestions()` 无生产调用方，且内部 4 道题“已加入复习但未整理”
- 位置：`lib/data/demo_data.dart:5-236`（定义），调用方：全仓无（`demoExams()`/`demoKnowledgePoints()` 仍在 `db_schema.dart:260,267` 的 `_seed` 里用）
- 现象：9 道演示题中 q-math-2（`:31`）、q-eng-2（`:69`）、q-pol-1（`:126`）、q-pol-3（`:162`）写了 `reviewJoined: true` 却没写 `isOrganized: true`（默认 false）。这违反“未整理的题没有加入复习入口”的模型；若将来有人重新启用演示题加载，这 4 道题会被 `dueToday`（要求 `isOrganized`）排除，看似加入、实则不复习。死代码本身 P0B2 报告已记过（“现无调用方，仅定义保留”），本次复核确认仍无调用方。相关文档问题见 SR-P1-34（D-04 未注明不预置）。
- 修的方向：要么删掉 `demoQuestions()`（`_seed` 明确不预置演示题，§6 第 1 条），要么把它 4 道题的 `isOrganized` 补 true 并加一条“演示题加载后复习计数正确”的测试。

#### SR-P2-14 `saveDraftBoxesInto`：任务行不存在时旋转角静默丢失；缺页键保留旧草稿
- 位置：`lib/data/db_collect.dart:228-285`（旋转角 update 在 `:269-277`，无影响行数检查）
- 现象：草稿保存是“删该页旧框 → 插新框 → 写 `page_rotations`”同事务；若任务行已被删（`update` 影响 0 行），框照样写进去了（成孤儿草稿），旋转角却丢了——调用方无从得知。反向：某页框被清空后，若调用方传的 `boxesByPage` 里根本没有该页的键（而不是空列表），该页旧草稿不会被删，残留。两处都是“调用方契约无校验”，不是已发生的 bug。
- 修的方向：旋转角 update 影响 0 行时抛错回滚；文档注明“被清空的页必须传空列表键”。

#### SR-P2-15 `_deleteTaskDirIfUnreferenced` 不查 `collect_tasks.source_path`
- 位置：`lib/data/db_collect.dart:131-155`（只查 `questions.source_path / page_image_path LIKE 'imports/<taskId>/%'`）
- 现象：拆分任务的 `source_path` 指向原任务目录（`imports/<原任务id>/original.pdf`，`collect_page.dart` 拆分任务构造）。删原任务时，若拆出题已全删、但拆分任务行还在，目录会被删，拆分任务行继续指着不存在的原文件。目前拆分任务不直接读 `source_path` 对应的文件（`_splitPagesFor` 只做字符串比对），所以实际影响≈0；但检查口径与函数注释“没有任何题还指向该目录”之外的任务引用存在缺口。
- 修的方向：补查 `collect_tasks.source_path LIKE 'imports/<taskId>/%'`，有引用就不删目录。

#### SR-P2-16 `recordSelfCheck` 按传入快照算新值，无乐观并发保护
- 位置：`lib/data/repository.dart:149-205`（`updated` 完全由传入的 `r.solvedCount`/`r.status` 推导，`db_questions.dart:22-48` 的事务本身没问题）
- 现象：两处自查若基于同一份旧 `CauseRecord` 先后提交，后提交的会覆盖先提交的计数（如两次快速点“已解决”，`solvedCount` 都按旧值 +1，本应 +2 只 +1）。UI 是串行操作，实际难触发；但数据层没有“按当前库内值递增”的防呆。
- 修的方向：事务内先读库内当前 `cause_records` 行再算，或 `review_count`/`solved_count` 用 SQL `+1`（`recordSelfCheckInto` 里 `review_count` 已是 `+1` 写法，`solvedCount` 可仿效）。

#### SR-P2-17 `_deleteFolderTxn` 每层递归全表读题（性能）
- 位置：`lib/data/db_catalog.dart:82-118`（每次递归 `txn.query('questions')` 全表 + `_fromRow` 逐行解码）
- 现象：文件夹嵌套删除时时间复杂度 O(层数 × 题数)，题库上千时删文件夹会明显变慢。正确性无问题，纯性能。
- 修的方向：按 `folder_ids` 在 SQL 层过滤（JSON 字段可用 `LIKE '%"id"%'` 粗筛再内存精筛），或一次读全表后内存递归。

### 收集 / 整理 / 详情（SR-P2-18～SR-P2-35）

#### SR-P2-18 切页自动检测只认 1 层框：只有独立题内框的页切走再回来会被重检测覆盖，独立内框丢失
- 位置：`lib/modules/collect/box_editor.dart:464-480`（`_autoDetectIfEmpty`）、`:370-380`（`_ingestDetected`）
- 现象：切页时的检测门控是 `(_boxesByPage[page] ?? []).isNotEmpty`，而 `_boxesByPage` 只存 1 层框；一页如果只有用户手画的独立题内框（`_standaloneInner`），门控误判为空页，跑一次检测；`_ingestDetected` 在检测无孤儿框时 `_standaloneInner.remove(page)`，手画的独立内框被清掉。`_openBoxEditor` 的首页面门控用的是 `draftsByPage[page]`（含 2 层），口径不一致。
- 修的方向：门控改成 1 层框、已挂内框、独立内框三者任一非空即跳过；或 `_ingestDetected` 在“替换”语义之外保留已有的独立内框。

#### SR-P2-19 “恢复自动框”的手动判断只认 1 层框：手画的独立题内框不弹确认就被替换掉
- 位置：`lib/modules/collect/box_editor.dart:495`（`hasManual = _boxes.any((b) => b.origin == 'manual')`，`_boxes` 只有 1 层）
- 现象：B3 把 `hasManual` 从恒真改成只认 `origin == 'manual'`，但检查范围仍只有 1 层框；手画的 stem/option/figure 独立内框（同样是 `origin == 'manual'`）不会触发“用自动框替换当前页的手动框？”确认，点“恢复自动框”后 `_ingestDetected` 直接覆盖。
- 修的方向：`hasManual` 同样检查 `_inners` 与 `_standaloneInner` 里 `origin == 'manual'` 的框。

#### SR-P2-20 重框模式“恢复自动框”只换 1 层框坐标，旧内框不跟随也不钳制
- 位置：`lib/modules/collect/box_editor.dart:543-600`（`_restoreAutoBoxForRework`）
- 现象：按 IoU 挑到检测框后只 `list[i] = clampToPage(picked.copyWith(id: target.id))`，`_inners` 里挂在该题下的旧内框坐标原样保留；新框移动/缩放后，旧内框可能落在新框外，确认后照此入库。草稿模式的 `_restoreAutoBoxes` 是整页替换（含内框重分组），口径不一致。
- 修的方向：替换后把该题的内框按新旧框的相对位置换算（或至少用 `_clampInner` 钳进新框），并在确认前校验内框是否仍在外框内。

#### SR-P2-21 内框模式下鼠标左键点空白处不退出，与帮助文案承诺不符
- 位置：`lib/modules/collect/box_editor.dart:1393` 起（画框层 `onPointerDown` 遇鼠标直接返回）、`:1168` 起（祖先级画布 `Listener` 只处理右键）、`:990-1000` 提示文案
- 现象：帮助与底部提示都写“点画布空白处、右键单击或按 Esc 退出内框模式”。触摸点空白处会经画框层 `_onDrawStart` → `_onDrawEnd`（小框当点击）退出；右键单击与 Esc 也能退；但鼠标左键点空白处没有任何处理（画框层忽略鼠标，祖先 Listener 只接右键），用户只能右键/Esc。
- 修的方向：祖先级 `Listener` 的 `onPointerDown` 里，鼠标左键落在画布空白处且处于内框模式时调 `_exitInnerMode()`（注意别抢框的拖动：只在未命中任何可交互框时退出，可复用 `_pointHitsInteractive`）。

#### SR-P2-22 确认拆题中途失败会留孤儿切片/烘焙页图；保留任务重建是两步写库、非事务
- 位置：`lib/modules/collect/collect_page.dart:505-575`（逐页写切片/烘焙图，`catch` 只提示 + `_load`）、`:576-620`（`confirmSplit` 后 `saveCollectTask(retained)` 与 `saveDraftBoxes` 两次 await，无 try/事务）
- 现象：切片是“先写盘、再进事务”，某页裁剪失败时前面已写的切片 PNG 与烘焙页图留在 `slices/` / `imports/<id>/pages/` 里，无库记录、无清理；四步事务本身失败时同理。保留任务重建分两步：第一步成功、第二步抛错时，任务已回“待框选”但未框页的草稿内框与旋转角没写回，且异常直接抛到 `_openBoxEditor`（无 try），无任何提示。
- 修的方向：失败时删除本次确认新建的切片/烘焙文件（记下已写路径清单再清）；保留任务重建包进一次事务或至少 try/catch + 失败提示与回滚。注意这不影响“未框页保留”本身的设计。

#### SR-P2-23 叠加层换算取第一个 1 层框：同一题有多个 1 层框时，挂在第 2 个框下的 2 层框会被按第 1 个框换算错位
- 位置：`lib/widgets/widgets.dart:71-97`（`realRegionRects`，第一个 1 层框即 `break`，其后所有 2 层框都按它换算）
- 现象：正常拆题是一题一框，但详情页重框允许一题多个 1 层框（`_reworkBoxes` 不限制 `newLayer1` 个数），此时属于第 2 个 1 层框的 2 层框仍按第 1 个框的坐标换算，叠加层位置错误。
- 修的方向：按 `parentBoxId` 把 2 层框归属到各自的 1 层框再换算；或在重框入口限制一题只能保留一个 1 层框（与拆题时一题一框的模型一致）。

#### SR-P2-24 叠加层“同区域多框取第一个”无确定性优先级（B3 遗留点 5，属实）
- 位置：`lib/widgets/widgets.dart:71-97`（`realRegionRects`，`if (out.containsKey(b.type)) continue`）；`lib/data/db_collect.dart:205-222`（`boxesForPageImageFromImpl` 无 `ORDER BY`）
- 现象：`boxesForTask` 有 `ORDER BY page ASC, id ASC`，但 `boxesForPageImage` 没有，行序即返回序（通常 rowid 序），同一区域多个框时画哪一个不确定。影响面：目前主要在演示题/老题的叠加层；SR-P1-5 的重复入库会放大它（重复的 stem 框谁先返回、画谁，全凭行序）。
- 修的方向：`boxesForPageImageFromImpl` 加 `ORDER BY page ASC, id ASC`（与 `boxesForTask` 对齐），或 `realRegionRects` 明确优先级（如取面积最大者）并写进注释/测试。

#### SR-P2-25 红色无框警告对“从未打开过的新导入任务”也会显示（B3 遗留点 2，属实，等 Meng 定）
- 位置：`lib/modules/collect/collect_page.dart:107-150`（`_load` 按草稿框逐页算未框页）、`:1124-1136`（行上警告）
- 现象：刚导入、还没打开过修框的任务没有草稿框，按“有未框页即警告”的字面规则同样显示“这张图还没有框”。B3 报告已记录，是否收窄到“部分框过 / 打开过”待 Meng 决定；本次自审不替他定，只确认行为与报告一致，无其他副作用（警告只影响行上文案，不影响导入/修框流程）。
- 修的方向：**等 Meng 决定**（Batch 3 待定事项）；若收窄，需在任务行记录“是否打开过修框 / 是否已有任意草稿框”的信号（目前 `_unboxedPagesByTask` 只有未框页数，区分不开）。

#### SR-P2-26 详情页新建文件夹：点对话框外关闭会被当成“放在顶层”创建，没有真正的取消路径
- 位置：`lib/modules/detail/question_detail_page.dart:595-630`，注释 `:606` 自述“点空白处关闭返回 null 与选‘顶层’同义，都当顶层处理”
- 现象：`_newFolder` 先弹输入框问名，再弹 `SimpleDialog` 问“放在哪里”，选项只有“顶层”和各顶层文件夹，没有“取消”；点框外关闭返回 null，代码当顶层创建。用户本想取消，却建了一个顶层文件夹（还会 `setState` 选上它并标脏）。
- 修的方向：`SimpleDialog` 加“取消”选项，用可区分的哨兵值（如空字符串）区分“取消”与“顶层”，点框外也按取消处理。

#### SR-P2-27 自定义错因与固定枚举同名时，详情页保存会静默丢掉，整理页会造成错因重复
- 位置：`lib/modules/detail/question_detail_page.dart:231-244`（`customNew` 过滤掉所有固定枚举名）；`lib/modules/organize/organize_page.dart`（`_addCustomType` 不校验是否与固定枚举或已选固定项重名）；`lib/models/models.dart:329`（`allCauses => [...errorTypes, ...customErrorTypes]`，不去重）
- 现象：详情页“新建错误类型”里输入“其他”这类固定名，芯片显示已选，保存时 `customNew` 把它滤掉，`_editErrorTypes` 里也没有，错因直接消失；整理页同名自定义会原样入库，`allCauses` 出现两次“其他”，详情页副标题的错因 pill 与复习记录的错因行都会重复（`syncCauseRecords` 内部用 `toSet` 去重，复习页不受影响，纯显示重复）。
- 修的方向：新建自定义时若与固定枚举同名，直接当作选中对应固定项（并提示），不再进自定义集合；或保存时把同名自定义合并进 `_editErrorTypes`。

#### SR-P2-28 毫秒级时间戳 id：文件夹 / 试卷 / 知识点快速连点可能互相覆盖
- 位置：`lib/modules/organize/organize_page.dart`（`_submitNewFolder`、`_submitNewExam` 的 `'folder-${ms}'` / `'exam-${ms}'`）；`lib/modules/detail/question_detail_page.dart`（`_newFolder`、`_newExam`、`_newKnowledgePoint` 同款）；`lib/modules/collect/collect_page.dart`（`_failTask` 的 id 还叠加 `fileName.hashCode`，同名同毫秒两次失败会互相覆盖）
- 现象：新建类 id 只有毫秒时间戳，没有随机后缀；同一毫秒内两次创建（如双击“添加”）会生成相同主键，后一次 `save` 覆盖前一次，前一个实体无声消失。框 id（`AppDatabase.newBoxId`，8 位随机十六进制）与拆题 id（`'import-$ts-$p-$i'`，含页与序号）已有防撞手段，新建文件夹/试卷/知识点没有。
- 修的方向：统一用 `newBoxId` 同款随机后缀，或复用一个 `newId(prefix)` 工具；`_failTask` 同理。

#### SR-P2-29 整理页修框切片整题卡未传学科对象
- 位置：`lib/modules/organize/organize_page.dart:902` 的 `QuestionSlice(question: q, maxHeight: 220)` 没传 `subject`，其余调用处（同页 `_paperImage`、详情页、错题本）都传
- 现象：仅当切片缺图走占位时，学科名/图标回退到 `Subject.byId`（新学科会显示成数学）。补传 `_subjectOf(q.subjectId)` 即可。

#### SR-P2-30 `_donePages` 只是本页装饰态
- 位置：`lib/modules/collect/box_editor.dart:198,1595-1615`
- 现象：“本页修完 ✓”不校验（0 框也能打勾）、不进草稿、不随取消保存，重开编辑器即丢；确认也不看它。现状无害，但按钮文案会让用户误以为“打勾 = 已保存/已确认”。
- 修的方向：要么让它真正进草稿/参与确认校验，要么改文案说明只是本页标记。

#### SR-P2-31 切页与取消保存草稿无 try
- 位置：`lib/modules/collect/box_editor.dart:440-460`（`_switchPage`）、`_foot` 的取消按钮先 `await _saveDraftIfNeeded()` 再 `pop`
- 现象：保存抛错时切页直接抛（`onTap` 未接异常）、取消时对话框关不掉且无任何提示。
- 修的方向：包 try + 失败提示即可。

#### SR-P2-32 `firstWhere` 无 `orElse` 的硬查（多处，命中即 `StateError` 崩溃）
- 位置：`lib/modules/collect/box_editor.dart:397`（`_enterInnerMode`）、`:826-835`（`_onDrawStart` / `_onDrawUpdate` / `_onDrawEnd` 里按 `_innerModeBoxId` 找外框）、`:669`（`_replaceBox` 内框分支的 `_inners[key]!`）
- 现象：目前可达路径较窄（删框时会清内框模式），但一旦命中就是 `StateError` 崩溃。
- 修的方向：补 `orElse` 兜底或进入内框模式前校验。

#### SR-P2-33 `CollectStatus.done` 无赋值处（死分支）
- 位置：`lib/modules/collect/collect_page.dart:107-150` 的 `splitPagesBySource` 与 `:629-640` 的 `_splitPagesFor` 里对 `done` 的分支实际走不到；`_statusPill` / `_taskActions` 里 `done` 的行也一样
- 现象：全仓 grep 无任何 `= CollectStatus.done` / `status: CollectStatus.done`。现状无害（防御性代码），但“已整理任务行”的删除确认实际走的是 `pendingOrganize` 分支，注释里“待整理 / 已整理”的说法应以此为准。
- 修的方向：确认 `done` 状态是否还有生产入口；没有则删分支或注明防御性保留。

#### SR-P2-34 死代码：`DashedDivider` 与 `InfoChip` 在 `lib/` 内零调用点
- 位置：`lib/widgets/widgets.dart:681`（`DashedDivider`）、`:762`（`InfoChip`）
- 现象：两处文档注释还写着“九页调用处不动 / 签名不变”，与现状不符。`EmptyState`（:1080）仍有调用（详情页题不存在时），不是死代码。
- 修的方向：确认无外部引用后删除两者，或留一个并补回调用；至少修正注释。

#### SR-P2-35 重复实现：`_subjectInitial` 与 `_dateText` 父页与队列弹窗各一份
- 位置：`lib/modules/organize/organize_page.dart:122` 与 `:2122` 的 `_subjectInitial`、`:519` 与 `:2131` 的 `_dateText`，父页与 `_QueuePopupState` 各一份，一字相同
- 修的方向：抽到一处共用即可。

### 错题本 / 复习 / 报告 / 首页（SR-P2-36～SR-P2-58）

#### SR-P2-36 文件夹同名判重只查同层兄弟，不查整科
- 位置：`lib/modules/wrongbook/wrongbook_page.dart:563-580`（`_addFolder`，`siblings` 为同父文件夹）、`:593-608`（`_saveRename` 同理）、`:685-730`（`_moveOneFolder` 只查目标同层）
- 现象：已定决定是“同一学科不能有两个同名文件夹”。现顶层已有“试卷”时，仍可在另一顶层文件夹下新建同名子文件夹“试卷”，或把文件夹移入含同名子的目标下（`_moveOneFolder` 的目标同名检查在 `:705-707` 也只查 `_subFolders(targetParentId)`）。同名文件夹跨层并存后，目录行靠“父名 / 子名”区分尚可辨认，但判重提示“已经有了”失去整科一致性。
- 修的方向：新建/改名/移入三处把判重范围改为整科（`_subjectFolders(subjectId)` 内按名判重，排除自身）；或由 Meng 改决定为“只同层判重”，并把该口径写进目录页注释。注意数据层 `upsertFolder`（`db_catalog.dart:378-388`）无唯一约束，判重只能靠页内逻辑。

#### SR-P2-37 错题本“学科首字母”排序写死数学/英语/其他三档，新学科排不准
- 位置：`lib/modules/wrongbook/wrongbook_page.dart:435-440`（`subjectRank`：`'math' => 0, 'english' => 1, _ => 2`）
- 现象：已定排序是“学科首字母 A→Z”。新学科（如化学、物理）一律 rank 2，与政治并列、只按创建时间倒序排，既不是首字母序，也不是入库序；三科以上时排序结果与下拉文案“学科首字母 A → Z”不符。注释（`:433-434`）自称“数学 S / 英语 Y / 政治 Z”，但代码并未按首字母算，而是按 id 硬编码。
- 修的方向：按学科名首字母（或库内学科顺序 + 名称）算 rank；未知学科不再统一落到 2。顺带与 SR-P0-2 一并修（`'subject'` 设置值与 `subj-asc/subj-desc` 的映射）。

#### SR-P2-38 目录页/书架的题数含已掌握题，但列表默认隐藏已掌握；“已解决 X 道不显示”提示的计数是整科口径，不是当前文件夹口径
- 位置：`lib/modules/wrongbook/wrongbook_page.dart:212-222`（`_folderCount`：只排除未整理与已归档，不排除已掌握）、`lib/modules/wrongbook/wrongbook_shelf.dart` 封面 `total`（同口径）；`lib/modules/wrongbook/wrongbook_list.dart:455-474`（`_buildMasteredNote`）
- 现象：目录行写着“5 道题”，点进去列表默认只显示未掌握的 3 道（另 2 道已掌握被 `_filteredAll` 的已掌握默认隐藏滤掉），用户会以为丢题；`_buildMasteredNote` 的 `hidden` 按整科算（`:458-467` 的 `where` 只限定 `_subjectId`，不限 `_folderId`），在某文件夹列表里却写“这科错因已全部解决 X 道”，X 与当前文件夹无关。
- 修的方向：二选一，需 Meng 定：(a) 目录/封面计数与列表默认视图同口径（扣掉已掌握，另在行上或提示里说明）；(b) 保持计数含已掌握，但 `_buildMasteredNote` 的 hidden 改为当前文件夹子树口径，并在目录行加“含已掌握”说明。

#### SR-P2-39 复习页“还没加入复习的题”把未整理题、无错因题也列进去了，而这些题根本加不进复习
- 位置：`lib/modules/review/review_page.dart:198-199`（`_load`：`if (!q.reviewJoined && !q.isArchived) notJoined.add(q)`），展示见 `:1298-1330`（`_buildNotJoinedBox`）
- 现象：`notJoined` 只排除已归档，未排除未整理与无错因。详情页规则是“未整理的题不能加入复习”（`question_detail_page.dart:1652`），且 `setReviewJoined` 在错因为空时返回 false（`repository.dart:36-40`）。于是复习页会列出一批点“加入复习”也加不进去的题名，并配文“到这些题的题目详情「复习记录」里点「加入复习」才会进来”，用户照做后发现无此按钮。
- 修的方向：`notJoined` 改为 `!reviewJoined && isOrganized && !isArchived && allCauses.isNotEmpty`；或分两行写清“未整理的题先去整理工作台”。

#### SR-P2-40 错题本批量加标签可新建含 `,` 或 `|` 的标签，绕过了 §6 第 4 条的禁令
- 位置：`lib/modules/wrongbook/wrongbook_page.dart:845-885`（`_batchAddTag`，新建标签直接 `repo.addTag(newCtrl.text.trim())`，无校验）；对照 `lib/modules/subjects/subjects_page.dart:215` 与 `:396`（两处均调 `hasBannedNameSeparator` 拦截，模型见 `lib/models/models.dart:214`）
- 现象：学科管理页新建/改名标签都禁 `,` 与 `|`，但错题本批量加标签的新建输入框不禁；数据层 `insertTag`（`db_catalog.dart:401-407`）亦无校验（`ConflictAlgorithm.ignore`）。虽多值字段已改 JSON、逗号不再切坏解析，但禁令本身被绕过，且该标签回到学科管理页后无法改名（改名校验会拦）。
- 修的方向：在 `_batchAddTag` 新建分支加同一校验（`hasBannedNameSeparator` → snack“不能含逗号或竖线”），与学科管理页文案一致。

#### SR-P2-41 批量操作用 `firstWhere` 查题、无事务、无失败反馈；跨学科勾选批量移文件夹时静默跳过
- 位置：`lib/modules/wrongbook/wrongbook_page.dart:845-1000`（`_batchAddTag` / `_batchMoveToFolder` / `_batchMoveOut` / `_batchFavorite` / `_batchArchive` / `_batchDeleteConfirmed`）
- 现象：(a) 六处循环均用 `_questions.firstWhere((x) => x.id == id)`，若勾选题在两次 `_load()` 间已被别处删掉/归档过滤掉，会抛 `StateError`，整个批量操作中断在中断处，之前已执行的留下、之后的不执行，且无提示；(b) `_batchMoveToFolder`（`:928-944`）对 `q.subjectId != target.subjectId` 的题直接 `continue`，但从“全部学科”入口（`filterCause` / 知识点筛选进列表，`_subjectId == null`）勾选跨科题时，这些题被静默跳过，选后清空、无任何说明；(c) 批量删除/归档逐条 `await`，中途失败即半截状态（“多个删除操作未包事务”亦是 MEMORY 记的已知尾巴）。
- 修的方向：循环内用 `firstWhereOrNull` 跳过已不存在的题并汇总提示；`_batchMoveToFolder` 在跨科跳过时 snack 告知跳过 N 道；批量删除/归档按 §4.2 模式包事务或至少失败回滚并报错。注意 `_batchFolderOptions`（`:911-917`）只返回当前学科文件夹，跨科场景下应在进入批量模式时就说明。

#### SR-P2-42 目录页文件夹拖拽调顺序：往下拖会多移一位
- 位置：`lib/modules/wrongbook/wrongbook_page.dart:765-790`（`_reorderFolder`）；缝隙渲染见 `lib/modules/wrongbook/wrongbook_directory.dart`（`_buildGapTarget(null, i)`，i 为 0..行数，行 i 之前）
- 现象：`_reorderFolder` 先 `removeWhere` 删掉被拖行，再 `insert(toIndex)`。缝隙下标是“删除前”的位置：把 A（第 0 行）拖到 A 与 B 之间的缝隙（index 1，期望不动）→ 删 A 得 [B, C…] 再插到 1 → [B, A, C…]，A 被移到 B 之后；往下拖一律多移一位，往上拖才正确。
- 证据：三行 [A, B, C]，拖 A 到缝隙 1，期望 [A, B, C] 不变，实际得 [B, A, C]。
- 修的方向：插入前按被拖行原下标修正目标下标（`if (toIndex > fromIndex) toIndex -= 1`，`fromIndex` 为删除前下标），或把缝隙下标定义为“删除后”的位置并改渲染侧。加一测覆盖上/下两个方向。

#### SR-P2-43 `_applyDrop` 的注释称“子文件夹拖到顶层行之间 = 移进该顶层”，但该路径实际走不通
- 位置：`lib/modules/wrongbook/wrongbook_page.dart:795-800`（注释） vs `lib/modules/wrongbook/wrongbook_directory.dart` `_buildGapTarget` 的 `onWillAcceptWithDetails`（`if (dragged.parentId != parentId) return false`）
- 现象：顶层缝隙只接受 `parentId == null` 的拖拽，子文件夹拖过去直接被拒；`_applyDrop` 的第三条注释与 `_buildGapTarget` 的实现矛盾，读代码会误判行为。实际把子文件夹移回顶层只能拖到「全部题目」行（`_DropKind.promote`），该路径本身是对的。
- 修的方向：删掉或修正 `_applyDrop` 的第三条注释，以 `_buildGapTarget` 的实现为准。

#### SR-P2-44 进错题本另一科/另一文件夹时，搜索与筛选条件不清零，旧条件带到新范围
- 位置：`lib/modules/wrongbook/wrongbook_page.dart:518-545`（`_openList` 只清 `_page/_selected/_batchMode`）、`:546-562`（`_openDirectory` 只清目录侧状态）、`:564-574`（`_openShelf`）
- 现象：数学书里搜“三角函数”、筛“仅收藏”后，返回书架打开英语书、进其目录/列表，搜索框与筛选仍是数学那套条件，列表可能为空，用户须手动点“重置”。`_resetFilters`（`:497-516`）存在但三处导航均未调用。
- 修的方向：`_openList` / `_openDirectory` 在切换学科时调用 `_resetFilters`（保留文件夹/学科归属本身）；或由 Meng 定为“筛选跨书保留”，并把该口径写进注释。

#### SR-P2-45 “最近一周”实际是 8 天；搜索日期须写无前导零格式才命中
- 位置：`lib/modules/wrongbook/wrongbook_page.dart:405-419`（`_filterTimeRange`：`limit = 7`，`age >= 0 && age <= limit`）；`:334`（`_searchHaystack` 的日期串）
- 现象：(a) `week` 取 `age <= 7`，含今天共 8 个自然日，与“最近一周”通常理解（7 天）差一天；(b) 搜索日期拼成 `2026-11-5`（月/日无前导零），搜 `2026-11-05` 命中不了，搜 `2026-11-5` 才能命中。
- 修的方向：(a) `age < 7` 或 `age <= 6`（由 Meng 定 7 天是否含今天）；(b) 日期串补零到 `yyyy-MM-dd`，或同时收两种写法。两者均为展示/过滤口径小偏差，无数据风险。

#### SR-P2-46 书架顶部入口的跨学科已归档视图无分页、无搜索
- 位置：`lib/modules/wrongbook/wrongbook_list.dart:1102-1140`（`_buildArchived`：`archived` 全量排序后直接 `_buildArchivedRows`，无 `_buildPagination`、无工具条）
- 现象：归档题一多，整页一次渲染全部行；且与书内已归档视图（走 `_buildList`，有分页）不一致。归档是只增不减的冷数据，量上来后首屏与滚动成本都高。
- 修的方向：复用 `_buildList` 的分页（或给 `_buildArchived` 加与书内一致的分页器，默认 10 条）；搜索可暂缓，先补分页。

#### SR-P2-47 复习页“已解决的错因”区与“还没加入复习的题”盒不分页
- 位置：`lib/modules/review/review_page.dart`：已解决区 `_buildCuredSection` / `_buildCuredRow`（渲染 `_filteredCured` 全部，分组无分页）；未加入盒 `_buildNotJoinedBox`（`:1298-1330`，全部题名拼进一个 `Text`）
- 现象：待解决列表有分页（默认 10），已解决区与未加入盒却全量渲染；题多时页尾很长，且未加入盒的长字符串无换行分行以外的结构。量级尚小时无感，是扩展性缺口。
- 修的方向：已解决区复用同一分页或折叠默认收起；未加入盒按学科分行、超出 N 道折叠。低优先级。

#### SR-P2-48 首页、错题本、复习页的 `_load()` 没有 try/catch，读库失败会一直转圈
- 位置：`lib/modules/home/home_page.dart:117-155`、`lib/modules/wrongbook/wrongbook_page.dart:147-186`、`lib/modules/review/review_page.dart:184-290` 的 `_load()` 均无 try/catch；对照 `lib/modules/report/report_page.dart:129-157` 与 `lib/modules/subjects/subjects_page.dart:126-158` 均有 try/catch + 错误横幅（`_loadError`）
- 现象：`repo` 任一调用抛错时，`_loading` 恒为 true，页面永远是 `CircularProgressIndicator`，无横幅、无重试入口。报告/学科页已证明项目内有现成错误态模式可复用。
- 修的方向：三处 `_load()` 包 try/catch，失败置 `_loadError` 并出与报告页同款横幅（留住旧内容或给重试按钮）。

#### SR-P2-49 复习会话建块时忽略错因筛选：一题带全部待治错因进会话（需 Meng 裁决）
- 位置：`lib/modules/review/review_page.dart:340-380`（`_buildBlocks`：按分组顺序取题后，`causes = _pendingByQ[qid]` 全部待治错因），调用方 `_startSession`（`:386-440`，含 `fromGroup` 跳转）
- 现象：列表按错因筛出“计算错误”后点某组“开始解决”，会话里该题的其他待治错因（如“审题失误”）也被带进来一并解决。代码注释（`:340-342`）明说“每题带它全部待治错因”是刻意设计（与列表头“ 一道题有多个错因时在列表里只出现一次，一道题里挨着解决完”一致），但与“按错因筛选”的用户预期冲突：筛出的错因之外的错因会被无意治愈。
- 修的方向：由 Meng 裁决：(a) 维持现状，把“会话按题走、筛选只定起点”写进列表页说明；(b) 会话建块只取筛选命中的错因（`fromGroup` 或 `_causeFilter`），其余错因留待下次。

#### SR-P2-50 设置页缓存清理预览只扫数据目录顶层，嵌套的缓存目录会被漏计
- 位置：`lib/modules/settings/settings_page.dart:540-600`（`_scanCacheSync` 的 `walk`）
- 现象：`walk(Directory d, {bool insideCacheDir = false})` 只 `listSync()` 当前目录一层，从不递归进普通子目录（`insideCacheDir: true` 的调用点不存在），顶层缓存目录虽在 `add()` 里递归计字节，但藏在某子目录下的 `cache/thumb/tmp` 目录不会被发现；预览数字“临时文件 X 个、缩略图 X 张、共约 X MB”可能偏小，清理也删不到它们。
- 修的方向：`walk` 对非缓存目录递归进入（`insideCacheDir` 透传），或改为整树递归扫描后按名归类。

#### SR-P2-51 第 8 科及以后的新学科颜色回落到第一色（与数学同蓝）
- 位置：`lib/modules/subjects/subjects_page.dart:295-303`（`_addSubject`：`_newSubjectColors.firstWhere((c) => !usedColors.contains(c), orElse: () => _newSubjectColors.first)`）；色表见 `:36-53`（7 色）
- 现象：7 色用完后第 8 科起一律拿 `_newSubjectColors.first`（蓝 `0xFF2E7CF6`，与数学同色），学科圆点、标题色、封面以外的学科色全部撞车。注释只写到“第 6、7 科不再回落数学蓝”，未覆盖第 8 科起。
- 修的方向：色表扩到 10 色以上，或用完后按色相轮转生成新色；低优先级（当前仅 3 科）。

#### SR-P2-52 封面学科名与“错 题 本”用固定字号，不跟全局字号缩放
- 位置：`lib/modules/wrongbook/wrongbook_shelf.dart` `_buildBook` 内：学科名 `TextStyle(fontSize: 52, letterSpacing: 3.12)`（固定值）、副标题 `fontSize: 16, letterSpacing: 13.6`（固定值）；对照同函数内其余尺寸均乘 `scale`（如 `SizedBox(height: 40.4 * scale)`、书高 `bookMinHeight * scale`）
- 现象：三档字号（标准/大/特大）下书体、计数条、按钮都放大，唯学科名与副标题不动；大字号时封面留白比例失衡（B2 报告的 74.4px 纵向排布只在标准字号下实测过）。
- 修的方向：两处字号与字距同乘 `scale`（并重测 B2 的 74.4px 占位在三档字号下的效果）；或由 Meng 定封面字不跟缩放并写进注释。

#### SR-P2-53 错题本列表页标题里文件夹分支与学科分支写出同一字符串，文件夹名从不显示
- 位置：`lib/modules/wrongbook/wrongbook_list.dart:21-27`（`title` 三元：`folder != null && folder.name.isNotEmpty` 分支与 `subject != null` 分支均为 `'${subject?.name ?? ''} · 错题本'`）
- 现象：进某文件夹的列表与进该科“全部题目”的标题完全相同，用户无法从标题分辨当前在哪个文件夹；`folder` 变量只用于该判断，其余无用。属死分支（非功能 bug）。
- 修的方向：文件夹分支标题改为 `'${subject?.name} · ${folder.name}'` 或删掉该分支（若刻意不显示文件夹名，删分支并留注释）。

#### SR-P2-54 从报告弱点行（无学科）或错因筛选进错题本列表时，打开的书外框 fallback 成数学封面色
- 位置：`lib/modules/wrongbook/wrongbook_list.dart:58`（`_openBookFrame(subjectId: _subjectId ?? 'math', ...)`）
- 现象：`WrongbookPage` 以 `filterCause` / `filterKnowledgePointId` 进列表时（`wrongbook_page.dart:128-133`，`_subjectId` 为 null），列表外框用数学蓝，与“跨学科列表”身份不符。报告点弱点行时带 `subjectId`，不走此分支；走此分支的是无学科的错因/知识点筛选入口。
- 修的方向：`_subjectId == null` 时外框用中性色或按列表首题学科色；低优先级。

#### SR-P2-55 学科管理封面选择器接了两套点按处理（外层 GestureDetector + QmCoverMini.onTap）
- 位置：`lib/modules/subjects/subjects_page.dart` `_buildCoverPicker` 内样式小图：外层 `GestureDetector(onTap: () => _setCover(s, style: style))` 包裹 `QmCoverMini(..., onTap: () => _setCover(s, style: style))`（`QmCoverMini` 内为 `_QmPressable`，见 `lib/widgets/uikit.dart:817-920`）
- 现象：同一动作接了两处回调，依赖手势竞技场只胜出一个才不致双写；当前实测未见双写（`_setCover` 本身幂等：同值 `saveSubject` + `_load`），但属于冗余接线，后续改任一处都易漏另一处。
- 修的方向：只留一处（建议留 `QmCoverMini.onTap`，删外层 `GestureDetector` 的 `onTap`，外层只保留布局）。

#### SR-P2-56 学习报告两处“近似口径”属实，属已裁决的残留而非新 bug（列出备查，不修）
- 位置：`lib/modules/report/report_page.dart:281-300`
- 现象：(a) 已解决/待解决按 `lastCheck` 过滤，`lastCheck == null` 视为在范围内、计入所有范围（`report_page.dart:284-295` 的 `(r.lastCheck == null || _inRange(...))`），从未自查的待解决错因在“本周”里也被计入；(b) “复查通过率”分母是范围内全部已判定自查记录（`judged`），并非仅复查记录（`review_history` 无复查备注字段，页头注释 `:30-33` 已明说“以全部已判定记录为近似”）。(a) 是 S8 B1 经 Meng 2026-11-13 裁决的口径，页头注释 `:24-29` 亦有说明；(b) 同为文档化近似。
- 修的方向：不修（除非 Meng 改裁决）。若将来 `CauseRecord` 补“治愈日期”与 `review_history` 补“是否复查”字段，两处可分别精确化；届时先改模型再改此页。

#### SR-P2-57 复习断点恢复条的范围文案写死“全部待解决错因”
- 位置：`lib/modules/review/review_page.dart:396-401`（`_startSession(resume: true)` 的 `scopeLabel = '全部待解决错因'`）
- 现象：断点本身是按当时筛选/分组建的队列，恢复时文案却一律称“全部”，与按学科筛选后暂停再恢复的实际范围不符（队列内容是对的，只有文案错）。
- 修的方向：恢复时按保存队列的学科范围生成文案，或把断点保存时连同范围标签一起存。

#### SR-P2-58 “重置”后排序回到设置默认值，而非既定“时间新→旧”（需 Meng 定）
- 位置：`lib/modules/wrongbook/wrongbook_page.dart:497-516`（`_resetFilters`：`_sort = _defaultSort`，注释称“排序回到设置里的错题本默认排序”）
- 现象：MEMORY 记的既定决定是“「重置」 beside filter clears search, all filters, sort back to time new→old”。若用户把设置默认排序改成“旧→新”或“学科首字母”，点“重置”后排序停在该默认值，而非新→旧，与决定字面不符。`_defaultSort` 本身取自设置（`:180`），链路自洽，只是与旧决定冲突。
- 修的方向：由 Meng 定：(a) 重置固定回 `'new'`（改 `_resetFilters` 与注释）；(b) 维持“回设置默认”，更新 MEMORY/决定记录。注意若选 (a)，SR-P0-2 修掉 `'subject'` 之前，重置到 `'new'` 反而能绕开 SR-P0-2 的崩溃路径。

### 服务层（SR-P2-59～SR-P2-77）

#### SR-P2-59 `_importPdf` 的存储估算把原文件算了两次，接近 2GB 上限时会误拒合法 PDF
- 位置：`lib/services/import_service.dart:356-363`
- 现象：`used = storageUsageBytes()` 时原文件已复制进 `imports/<task>/original.pdf`（已计入 `used`），估算却又加了一次 `fileSize`：`used + fileSize + total × 2MB > 2GB`。只在总占用距 2GB 不到一个 PDF 大小时触发，误拒本可导入的 PDF，提示却是“空间不足”，用户删文件也未必能对上账。
- 修的方向：估算改为 `used + total × estimatedBytesPerRenderedPage`（原文件已在 `used` 里）。

#### SR-P2-60 任务 id 是“毫秒时间戳 + 批内序号”，同一毫秒内两次导入可能撞 id
- 位置：`lib/services/import_service.dart:184`（`'task-${DateTime.now().millisecondsSinceEpoch}-$i'`）
- 现象：两次 `enqueue` 在同一毫秒启动且序号相同（都是 `$i = 0`）时生成同一 id，后一次 `upsertCollectTask` 会覆盖前一次的任务行。概率低但非零（快速连续导入/自动化调用时），丢任务且无报错。
- 修的方向：id 后缀加随机段（如 6 位随机数）或改用递增计数器 + 随机段。

#### SR-P2-61 图片解码失败时静默按原图继续进 `needBox`，损坏图片不进 `failed`
- 位置：`lib/services/import_service.dart:300-307`（EXIF 分支的 `catch (e)`：注释“读不到 / 解码失败：原图已拷进库，仍可继续”）
- 现象：改后缀的非图片文件（如 `.txt` 改 `.jpg`）能通过扩展名检查，解码失败后仍建成 `needBox` 任务；修框编辑器打开时才暴露解码失败。失败发现得晚，任务状态误导（“待框选”实际是“打不开”）。
- 修的方向：解码失败且文件确实不是图片时进 `failed` 并提示“这张图片打不开”；仅当失败原因不明确时才保留现有降级。

#### SR-P2-62 复制进度每次百分比变化都写一次库，一个文件最多约 70 次写库
- 位置：`lib/services/import_service.dart` 复制循环内 `onProgress` + `_updateProgress`（0→70% 每 1% 一次）；`_updateProgress` 本身只写 progress、不 bump（节流注释属实，但写库次数未节流）
- 现象：与注释“§4.3 节流”的意图不完全一致——状态变化确实节流了，进度写库没有。机械硬盘/慢盘上导入大文件时多余写放大；一般 SSD 上无感。
- 修的方向：进度写库节流到每 5% 或变化 ≥5 个百分点时写一次，UI 回调保持逐次。

#### SR-P2-63 `QmSegmented` 禁用态是双重 0.45 透明度（实际约 0.20），目前未触发
- 位置：`lib/widgets/uikit.dart:1073-1074`（`if (!enabled) return Opacity(opacity: 0.45, child: body)`）+ `:248`（`_QmPressable` 在 `onTap == null` 时又包一层 `Opacity(0.45)`）
- 现象：`onChanged == null` 时每段先被 `_QmPressable` 置 0.45，外层再乘 0.45，整体约 0.20，远低于 HTML `.btn:disabled{opacity:.45}` 的规定。核查两个调用点（`report_page.dart:332`、settings `_segmented`）目前都传非空 `onChanged`，线上无禁用态分段控件。
- 修的方向：去掉 `QmSegmented` 外层的 `Opacity`，只留 `_QmPressable` 的一层；或反过来让 `_QmPressable` 接受“已由父级处理透明度”的标志。

#### SR-P2-64 `QmChip` 可删除 + 可点双区时，内外两层 Tap 识别器竞争同一手势
- 位置：`lib/widgets/uikit.dart:535,619-640`（`bothZones` 时外层 `_QmPressable(onTap: onTap ?? onDelete)` 包着内层两个 `GestureDetector(onTap: onTap / onDelete)`）
- 现象：点标签、点 `×` 都同时经过两层 Tap 识别器，最终谁赢依赖手势竞技场的裁决顺序；无单测覆盖该分支。目前未观测到双触发，但结构脆弱，后续改动容易把它变成“点一次删两次/切换两次”。
- 修的方向：只留一层手势——外层 `_QmPressable` 的 `onTap` 传 null（只做视觉与焦点），点按全由内层两个 `GestureDetector` 承担；或补一个双区点按单测钉死行为。

#### SR-P2-65 `AppTheme` 的主题按钮垂直内边距是 12，与 token 的 `.btn 9px 20px` 不一致
- 位置：`lib/theme/app_theme.dart:121`（`vertical: 12 * scale`）；对照 `lib/theme/design_tokens.dart`（`buttonPaddingV = 9`，注释“.btn 9px 20px”）与 `QmButton`（用 9）
- 现象：走 `ThemeData` 的 `FilledButton/OutlinedButton/TextButton`（如对话框按钮）比 `QmButton` 高约 6px，两套按钮高度不统一。
- 修的方向：`_build` 里的 `buttonPadding` 改用 `DesignTokens.buttonPaddingV/buttonPaddingH`，与 `QmButton` 同源。

#### SR-P2-66 新学科在深色下直接用库里存的饱和色，与“深色只用冷雾色”不一致
- 位置：`lib/theme/design_tokens.dart`（`subjectColor`/`subjectInk` 的 `stored != null` 分支：预设三科之外直接返回存色，不分亮深）
- 现象：新学科在深色模式下圆点/标签用的是亮色轮换色（如饱和蓝/绿），与预设三科深色下的雾色（`#87A9CC` 等）不是同一档视觉。新学科一多，深色导航/标签里出现刺眼的饱和色点；S8A2 只定了“新学科用存色”，没定深色怎么处理。
- 修的方向：深色下对存色做处理（如与深底 `#262B33` 按 15% 混色，复用 `subjectSoft` 深色分支的做法）或由 Meng 明确接受现状。

#### SR-P2-67 复查提醒先写“今天已提醒”再弹框，弹框失败则当天提醒永久丢失
- 位置：`lib/app.dart:171`（`saveLastRecheckReminderDate` 在 `showDialog` 之前）；`lib/services/recheck_reminder.dart` 四条件本身无误
- 现象：写库与弹框之间若上下文失效、弹框抛错，当天已被标记为提醒过，`_reminderChecked` 又保证一轮应用只判断一次，提醒不再出现。小概率丢一次提醒；注释里已承认“弹框本身失败也不再重复弹”，是已知取舍但顺序可以更稳。
- 修的方向：`showDialog` 返回后再写日期；或写库失败/弹框失败时不写日期。

#### SR-P2-68 `readZip` 不解析中央目录，不支持带数据描述符的 zip；只含目录条目的空 zip 静默返回空列表
- 位置：`lib/services/zip_archive.dart`（`readZip` 按 local header 顺序读，遇中央目录/结束标记即停；`entries.isEmpty && off == 0` 才抛错）
- 现象：流式写入的 zip（local header 里 flag bit 3 置位、尺寸在数据后的描述符里）会被误读（尺寸取 0），随后以“结构损坏”抛错，文案没说明是这种 zip 不支持。只含目录条目的 zip（`off > 0` 但无文件条目）返回 `[]` 而不报错。单个条目的解压在累计 `total` 检查之前完成，超大单条目会先占满内存再触发 4GB 上限。自家备份不受影响（写出方从不置 bit 3）；用户用外部工具重打包的 zip 可能被拒；两个恢复入口（`db_backup.dart`）都会因缺 `backup.json` 而拒掉空包，所以无静默恢复风险。
- 修的方向：按中央目录校验条目数与偏移；解压前先用 local header 的 `rawSize` 做上限预判；空条目列表直接抛错。

#### SR-P2-69 `_decode` 从不 dispose `Codec`，每次解码漏一份 native 资源
- 位置：`lib/services/page_image_pipeline.dart:202`（`instantiateImageCodec` 后只取 `frame.image`，codec 未 dispose）；同款调用在 `lib/services/yolo_onnx_service.dart:145`
- 现象：`Codec.dispose()` 未调用；`page_image_pipeline` 的 `cropBoxPng`/`rotateImageBytes`、`detectPage` 每页都会走这条路。单次泄漏小，高频修框/批量检测时 native 资源累积；目前未观测到可感知的内存问题。
- 修的方向：`try/finally` 里 `codec.dispose()`（需先确认当前 Flutter 3.47 的 `Codec` 有公开 `dispose`）。

#### SR-P2-70 `rotateBoxToRotatedPage` 钳制时只钳左上角，不缩宽高，页外伸入的框会被拉宽
- 位置：`lib/services/page_image_pipeline.dart:66`（`w: nw.clamp(0.0, 1.0 - nx.clamp(0.0, 1.0))`；`nx` 被钳到 0 但 `nw` 未减去被裁掉的部分）
- 现象：如 `x = -0.1, w = 0.5` 的框，钳制后变成 `x = 0, w = 0.5`（应为 0.4），框整体右移且变宽；YOLO 输出本身都在页内，触发需手画/外部输入的越界框。低概率的框错位，仅影响越界输入。
- 修的方向：先钳 `x/y`，再按 `w = min(w, 1 - x)` 且从被裁一侧扣除溢出量（或复用 `clampToPage` 的同一钳制逻辑）。

#### SR-P2-71 YOLO 报告过期：仍写“模型缺失时回退占位框”，与现行代码不一致
- 位置：`docs/ui-replication/YOLO-INTEGRATION-REPORT.md` §2（“模型缺失、加载失败或图片文件不存在时回退占位（一页一个整题框）”）、§8（“Meng 需自己推这两个文件”）
- 现象：现行 `yolo_onnx_service.dart` 的 `DetectionResult` 注释与实现都是“模型失败不回占位框，返回空框 + `usedFallback: true`”；第 2 层模型已移出仓库且暂缓，只需第 1 层。文档与代码口径分裂，后续接手者会按报告去找并不存在的占位逻辑。
- 修的方向：更新报告 §2/§8，与 D-23“只接第 1 层、失败不回占位”对齐；§6 的 388/388 测试数也已过期（现为 628），顺手更新。

#### SR-P2-72 死代码 / 无用 API / 重复逻辑（第 2 层残留与“暂缓”一致，但应标注）
- 位置：`lib/services/import_service.dart:139` `ImportService.isAllowed`（全仓库零调用）；`lib/services/pdf_render_service.dart:189` `PdfRenderService.renderPagePng`（生产代码零调用，只有测试用）；`lib/theme/design_tokens.dart` `ScaledTokens.s()`（零调用）；`lib/services/yolo_onnx_service.dart:59` `@Deprecated modelAsset` getter（零调用的兼容垫片）；`yolo_onnx_service.dart:70-93` 第 2 层占位常量（`intraModelAsset`/`intraInputSize`/`intraConfThreshold`/`intraClassTypes`/`crossClassIouThreshold`，与“第 2 层暂缓、`intraEnabled = false`”一致，是有意的再接入记录，但其中 `crossClassIouThreshold` 还在第 1 层调用里传参，单类时跨类去重是空操作，容易误读为生效参数）；`yolo_onnx_service.dart` `_nms` 与 `_crossClassNms`（两段逐字相同的实现，同是按置信度排序后 IoU 压制）
- 修的方向：删 `isAllowed`/`ScaledTokens.s()`/`modelAsset`；`renderPagePng` 标注“仅测试用”或移到测试 helper；第 2 层常量集中加一句“暂缓、再接入时启用”的注释（已有部分注释，补齐 `crossClassIouThreshold` 在第 1 层是空操作这一点）；`_crossClassNms` 复用 `_nms` 的实现。

#### SR-P2-73 `TextScaler.linear(scale)` 完全覆盖系统字号缩放，无障碍大字号被三档设置取代
- 位置：`lib/app.dart`（`builder` 里 `media.copyWith(textScaler: TextScaler.linear(scale))`）
- 现象：三档（1.00/1.15/1.30）是唯一缩放来源，系统级字号设置被丢弃；`qmScaleOf` 也只读这个值。按 D4 设计是既定行为（字号只乘一次），但依赖系统大字号的用户会发现应用内字号不受系统控制。
- 修的方向：由 Meng 定夺：维持现状（明确写进决定），或取 `max(设置档, 系统缩放)`。

#### SR-P2-74 切片解码的 `cacheWidth` 不含 `devicePixelRatio`，高分屏切片偏糊
- 位置：`lib/widgets/widgets.dart:396`（`cacheWidth: (maxHeight * 2).ceil()`，`maxHeight` 是逻辑像素）；`:609`（`cacheWidth: 128` 写死）
- 现象：2x/3x 屏上解码分辨率只有逻辑尺寸的 2 倍，低于显示所需像素；注释说“按显示尺寸解码，不解全分辨率大图”是对的，但“显示尺寸”应乘 `devicePixelRatio`。高分屏上切片文字轻微发虚；低分屏无影响。
- 修的方向：`cacheWidth` 乘 `MediaQuery.devicePixelRatioOf(context)`（并设上限防爆内存）。

#### SR-P2-75 `_ZoomDialogState.build` 里给 `_dialogScale` 赋值（build 内改状态）
- 位置：`lib/widgets/widgets.dart:940`（`_dialogScale = scale;` 在 `build` 内）；`:853` 声明
- 现象：`_dialogScale` 只在 `_multiply` 的 fallback 视口尺寸里用到，而 `_multiply` 只在按钮/滚轮回调里触发（build 之后），目前工作正常。build 内写字段是坏味道，后续若有人在 build 流程里读它会拿到上一帧的值。
- 修的方向：移到 `didChangeDependencies` 或直接用局部变量传参。

#### SR-P2-76 多处 UI 线程同步文件 IO（已知、已实测很小）
- 位置：`lib/services/yolo_onnx_service.dart:144-146`（`existsSync`/`readAsBytesSync`）、`lib/services/import_service.dart:74`（`pageImageRelativeForTask` 内 `existsSync`）、`lib/widgets/widgets.dart`（`QuestionSlice`/`CompactSliceThumb` 的 build 内 `existsSync`）
- 现象：P0.5 报告已实测同步读 1653×2200 PNG 约 0.22–3.2ms，解码 10–27ms；打开慢的主因是 YOLO 推理约 3–6 秒，不是同步读。目前无可感知卡顿；P05 报告原话“生产用异步读或 isolate 仍值得做”。
- 修的方向：低优先级；后续优化打开体感时优先把推理放后台、先显页图，而不是只改读图方式。

#### SR-P2-77 三组单测首次并行跑时 `pdf_render_service_test.dart` 出现 10 项失败，复跑全过（测试侧观察，非产品 bug）
- 位置：`test/pdf_render_service_test.dart`（与 YOLO/P05 两组并行时）
- 现象：首次三组并行：PDF 组 10 项失败（含 21 页上限、3 页导入、加密 PDF 导入等）；随后 PDF 组单独跑 13/13 通过，三组并行复跑 50/50 通过。与 P0B2 报告里“固定等待在全量并行时会因 CPU 争用超时”同源——1.5 CPU 下 YOLO 推理（每页 3–6 秒）与 PDF 渲染抢 CPU，超时类失败是抖动，不是回归。
- 修的方向：不动产品代码；给耗时测试留超时余量，或把真实推理测试与 PDF 测试分开跑。

### 文档（SR-P2-78～SR-P2-90）

#### SR-P2-78 边界文档 §4.2：“框相互重叠时在确认时提示”措辞弱化
- 位置：`docs/quiz-master2-mo-kuai-bian-jie-hua-fen.md` §4.2“确认校验：框相互重叠时在确认时提示”
- 现状：重叠时确认按钮直接禁用、无法确认，另有行内“框重叠”警告（“有框重叠了，请调开再确认”），不是“确认时提示一下、仍可确认”。证据：`lib/modules/collect/box_editor.dart:920-921`（`confirmEnabled = total > 0 && !overlap`）、`:1028-1032`（重叠警告）。
- 修的方向：改为“框重叠时确认按钮禁用并行内警告，调开后才能确认”。

#### SR-P2-79 边界文档 §4.4：大卡片滚动容器“最多一次性展示两道题”
- 位置：同上 §4.4“大卡片滚动容器：大卡片列表是一个固定高度的容器，最多一次性展示两道题，超过两道就在容器内用滚轮滚动”
- 现状：>2 张卡时固定高度 466px 的容器约展示 2.5 张卡（第三张露一半），不是整两道。证据：`lib/modules/wrongbook/wrongbook_list.dart:687-700`；`lib/theme/design_tokens.dart:646`（`cardsScrollHeight = 466`）。
- 修的方向：改为“约 2.5 张卡（第三张露一半）”。

#### SR-P2-80 边界文档 §4.4：筛选条件“复习状态”应为“错因状态”
- 位置：同上 §4.4“筛选为折叠式面板，含文件夹、试卷、错误类型、时间、复习状态、标签……”（见 SR-P1-25 同句）
- 现状：面板下拉名为“错因状态”，选项为全部 / 待解决 / 解决中 / 已解决 / 复查；旧“复习状态”是翻卡模型用语。证据：`lib/modules/wrongbook/wrongbook_list.dart:283-300`（`'错因状态'` 下拉）。
- 修的方向：统一改为“错因状态”。

#### SR-P2-81 边界文档 §5.1：“复习状态、已复习次数与下次复习时间”措辞过期
- 位置：同上 §5.1“单道题的完整呈现：……以及复习状态、已复习次数与下次复习时间”
- 现状：题级“下次复习时间”字段已删（详情页旧的复习状态下拉与下次复习日期输入已删）；现状是每条错因记录自带的“下次复查日”（`recheckDate`），复习次数（`reviewCount`）仍保留显示。证据：`lib/modules/detail/question_detail_page.dart:17`；`:1587-1611`（每错因“下次复查 …”）。
- 修的方向：改为“每条错因的解决状态、解决次数与下次复查日，以及复习次数”。

#### SR-P2-82 边界文档 §3：“未确认 3 个页面、4 行”自相矛盾
- 位置：同上 §3“说明：共 8 个页面、9 条路由。已确认 5 个页面（5 行）；未确认 3 个页面、4 行（学科管理与设置是同一模块两条路由，所以在表中占两行）”
- 现状：未确认的页面实际是 4 页（题目详情、学习报告、学科管理、设置），不是 3 页；“3”是模块数（学科管理与设置算一个模块），与“页面”混用。证据：§3 表格本身列出未确认 4 行（详情、报告、学科管理、设置）。
- 修的方向：改为“未确认 4 个页面、4 条路由、3 个模块”；并随 SR-P1-27/SR-P1-28 修订确认状态后重新计数。

#### SR-P2-83 边界文档 §1/§3：“8 个页面 / 9 条路由”应为“8 个模块 / 9 条路由”
- 位置：同上标题“每个页面一个独立模块 · 8 个页面 / 9 条路由”；§3“共 8 个页面、9 条路由”
- 现状：页面实际是 9 个（首页、收集、整理、错题本、详情、复习、报告、学科管理、设置）；8 是模块数（学科管理与设置合为一个模块）。证据：`lib/app.dart` 9 条路由；`lib/modules/` 下 9 个页面目录。
- 修的方向：改为“8 个模块 / 9 个页面 / 9 条路由”，或直接写“9 个页面 / 9 条路由”并注明模块数。

#### SR-P2-84 边界文档 §5.3：字号写“标准 / 大”，缺“特大”
- 位置：同上 §5.3“设置：主题（默认跟随系统、回退亮色，亮 / 深可切换）、字号（标准 / 大，在设置内调整，首页不放字号开关）”
- 现状：字号三档——标准 / 大 / 特大。证据：`lib/models/models.dart` `AppSettings.fontSize` 注释 `standard / large / extraLarge`；代码地图 §3 同样写三档。
- 修的方向：改为“字号（标准 / 大 / 特大）”。

#### SR-P2-85 边界文档 §1/§5.3：“学科管理与设置同属一个模块”与代码结构及拆分表述不一致（需 Meng 定）
- 位置：同上 §1“学科管理与设置同属一个模块、占两条路由”；§5.3“学科管理 /subjects 与设置 /settings 合为一个模块”
- 现状：2026-11-12 已决定将两者拆分为两个页面（`lib/modules/subjects/` 与 `lib/modules/settings/` 各自独立的页面文件与路由）；“同一模块”的说法与“拆分为两个页面”的决定及代码结构并存，未作解释。证据：`lib/modules/subjects/subjects_page.dart`、`lib/modules/settings/settings_page.dart` 各自独立。
- 修的方向：二选一，需 Meng 定——(a) 明确“模块”定义不变（低频维护类页面合为一个模块，两条路由），在 §1 加注解释；(b) 改为两个模块，同步 §3 计数与 §6/§7 的增减模块示例。

#### SR-P2-86 README：“第 2 层已移除”措辞过重
- 位置：`README.md`“YOLO 第 1 层已接真模型……第 2 层已移除（`intraEnabled=false`，模型需重训，再接入点见该文件注释）”；结构树中 `yolo_onnx_service.dart` 行同款表述
- 现状：第 2 层是暂缓/禁用，不是移除——`_detectIntra`、后处理 `decodeYoloOutput`、归属 `groupInners`、`QuestionBox.layer`、修框内框模式、手画二层框存库均保留；训好模型放回即可再接。证据：`lib/services/yolo_onnx_service.dart:67,244-274`；D-23。
- 修的方向：改为“第 2 层暂缓（`intraEnabled=false`，模型需重训；检测逻辑与数据模型保留，见 D-23）”，与代码地图 §8 口径一致。

#### SR-P2-87 README：结构树未列 B4 新增文件
- 位置：`README.md`“结构”树：`data/database.dart`、`modules/` 只列目录
- 现状：B4 后新增 `lib/data/db_*.dart`（10 个 part 文件）、`lib/modules/collect/box_editor.dart` / `collect_widgets.dart`、`lib/modules/wrongbook/wrongbook_*.dart`（5 个），结构树仍按拆分前描述。证据：见 SR-P1-39 的 `wc -l` 与 part 声明。
- 修的方向：在结构树中补一行说明 B4 拆分（入口 + part 文件），或指向代码地图 §2 的最新文件表。

#### SR-P2-88 decision-log D-06：“每科另三数”措辞歧义
- 位置：`docs/decision-log.md` D-06“每科另三数：要复习 / 待复查 / 已解决（不显示总题数）”
- 现状/歧义：首页学科格实际只显示两数——“要复习 N 道 · 待整理 M 道”；三数（要复习 / 待复查 / 已解决）是 `subjectCounts()` 的口径，用于错题本封面徽章，不是首页学科格。证据：`lib/modules/home/home_page.dart:603`（学科格两数）；`lib/data/repository.dart:96-105`（`subjectCounts` 注释“各科三数：要复习 / 待复查 / 已解决”，“错题本封面三数会显示 0”）；`lib/modules/wrongbook/wrongbook_page.dart:154` 取 `subjectCounts()` 供书架。
- 修的方向：D-06 补注“三数指错题本封面徽章口径（`subjectCounts`）；首页学科格为要复习 / 待整理两数”。

#### SR-P2-89 四方分工：“眼前第一步”时间线过期
- 位置：`docs/四方分工.md`“眼前第一步：Meng 先做 Win11 验收；Muse 和 CodeBuddy 待命；GPT 待命审验收结果。验收完按上面分流修，再跑一轮。”
- 现状：该段写于 2026-11-14 18:26，此后 Batch 3 最终验证与 Batch 4 拆分已完成，当前阶段是“最终自审 → Meng 决定是否推送”，不是“验收前待命”。证据：`docs/ui-replication/B3-SUMMARY.md`、`B4-SUMMARY.md`（下一步均为最终自审）。
- 修的方向：更新为当前阶段（最终自审中，推送待 Meng 在自审汇总后决定），或注明该段为 2026-11-14 18:26 的快照。

#### SR-P2-90 代码地图 §5：Dart 速成引用的 `database.dart` 内函数已随 B4 搬家
- 位置：`docs/代码地图.md` §5（如“`lib/data/database.dart`，`_toRow`（节选）”）、§4/§8 中按 `database.dart` 行号引用的实现位置
- 现状：`_toRow` / `_fromRow` / 编解码已移至 `lib/data/db_codec.dart`；B3 报告引用的 `database.dart` 行号（L148、L2152 等）在 B4 后已失效。证据：`lib/data/db_codec.dart:1`、`:63-68`（`_toRow` 现址）。
- 修的方向：§5 示例出处改为 `db_codec.dart`；全文档按 B4 后的文件重核行号引用（可与 SR-P1-39 合并修）。

### 第四批拆分（SR-P2-91～SR-P2-92，无 P0/P1）

#### SR-P2-91 B4-WRONGBOOK / B4-SUMMARY 的 wrongbook 行数口径与实测不符（文档错误）
- 位置：`docs/ui-replication/B4-WRONGBOOK.md`（“`wrongbook_page.dart`（1141 行）”、“总行数 3718 → 3740”）、`docs/ui-replication/B4-SUMMARY.md`（同口径）
- 现象：实测 `lib/modules/wrongbook/wrongbook_page.dart` 为 **1147 行**，6 文件合计 **3746 行**，均比报告多 6 行。其余两处拆分行数与报告一致（database 541 + 10 文件 2964；collect 1316 + 2021 + 44 = 3381）。差额 6 行正好等于新增的 5 行 `part` 声明 + 1 行 `_update` 转发，疑似报告计数时把“原段长度”当成了“落盘后行数”。仅文档数字不准，无行为影响。
- 证据：`wc -l lib/modules/wrongbook/wrongbook_*.dart`：1147（page）/ 496（shelf）/ 601（directory）/ 1142（list）/ 278（cover）/ 82（widgets），合计 3746；`part` 声明在 `wrongbook_page.dart:9-13`，`_update` 在 `:1006`。
- 修的方向：把两份报告中的 1141 → 1147、3740 → 3746，或注明“行数不含新增的 part 声明与 `_update` 转发”。

#### SR-P2-92 6 个拆分文件未通过 `dart format --set-exit-if-changed`（格式漂移）
- 位置：`lib/modules/collect/box_editor.dart`（1 处）；`lib/modules/wrongbook/wrongbook_page.dart`、`wrongbook_shelf.dart`、`wrongbook_directory.dart`、`wrongbook_list.dart`、`wrongbook_cover.dart`（多处）
- 现象：`dart format --output=none --set-exit-if-changed` 对 20 个拆分文件检查，6 个报 `Changed`。漂移形态均为纯空白：参数表换行方式（如 `box_editor.dart:818` 的 `_onDrawStart` 参数表）、多行调用本可合并单行、整块缩进差一档（如 `wrongbook_shelf.dart:211-244` 的 `Color.fromRGBO` 与 `ClipRRect` 块）。`database.dart` + 10 个 `db_*.dart`、`collect_page.dart`、`collect_widgets.dart` 全部干净（0 changed）。无行为影响；`analysis_options.yaml` 未强制格式，`flutter analyze` 仍为 0 问题。
- 证据：`dart format` 对照输出；拆分前备份 `~/workspace/demo-db-backup/database-before-b4/database.dart.before-b4` 本身也不满足 format 检查，说明至少 database 侧的漂移是既有的。但 wrongbook / collect 无拆分前备份可逐行比对，且两份 B4 报告均称移动代码“逐字”，故无法从现有材料完全排除“漂移由拆分引入”的可能——只能说漂移形态（可合并单行的多行调用、与方法体无关的缩进差）与既有手写格式一致，不像机械搬移会产生的改动。
- 修的方向：对 6 个文件跑一次 `dart format`（纯空白改动，不改行为）；或先与拆分前原文逐行比对确认漂移早于 B4，再决定是否格式化。注意：格式化会改动行号，`B4-WRONGBOOK.md` 的原行号对照表需同步失效声明。

---

## B3 汇总遗留点逐条核实结论

| # | B3-SUMMARY 遗留点 | 核实结果 |
|---|---|---|
| 1 | 模型文件未被 `.gitignore` 忽略 | **属实**，见 SR-P0-3；等 Meng 决定 |
| 2 | 红色无框警告的范围（新导入任务也警告） | **属实**，见 SR-P2-25；等 Meng 决定 |
| 3 | `_importPdf` 末尾 `upsertCollectTask(done)` 在 try 之外 | **属实**，见 SR-P1-4 |
| 4 | `CompactSliceThumb` 无 `errorBuilder` | **属实**，见 SR-P1-15（两组独立核实一致） |
| 5 | 叠加层同区域多框取第一个、无确定性优先级 | **属实**，见 SR-P2-24 |
| 6 | 详情重框事务前写盘可能残留孤儿切片 | **属实**，见 SR-P2-3（仅孤儿文件） |
| 7 | 整理队列确认框非路由级弹窗（无路由返回键处理，Esc 由队列层自己处理） | **属实但已处理**：B3 方案是在队列层自身 Stack 顶层渲染 `ModalBarrier` + `AlertDialog`（`organize_page.dart:2512-2540`），Esc 先关确认框再关队列层；收集组核实删除确认全走模态弹窗无残留。属文档化取舍，不列入问题清单 |
| 8 | 边界文档 §4.2/§4.3 仍有范围外的旧描述 | **属实**，见 SR-P1-18～SR-P1-24、SR-P2-78（§4.2 四处 P1 + 一处 P2；§4.3 三处 P1）。B3-SUMMARY 称“§4.2/§4.3/§5.1 二层描述按现状修正”本身属实——二层相关文字已修，遗留的是二层之外的旧描述；另 §5.1/§5.2/§5.3 的“未确认”过期见 SR-P1-27～SR-P1-30 |
| 9 | 过程中收集工人曾误杀两个疑似兄弟工人的 flutter_tester 进程 | 过程事项，无残留影响（本次 `flutter analyze` 正常跑完；全量测试 628/628 已覆盖重验） |
| 10 | organize P1-1 对照用例批量跑时曾偶发失败 | **未复现**：拆分验证组分 5 批跑完 45 个文件 628/628 通过；服务层组亦有并行抖动记录（SR-P2-77），属 CPU 争用超时抖动，非产品回归 |

---

## 审过且干净的地方（各组抽查结论汇总）

- **B4 拆分完整性**：database 10 个 part 接线正确，56 个公开静态转发签名逐字一致、无新增无遗漏，31 个私有静态全部在 part 文件里仅一次顶层定义，67 个 extension 方法无遗漏、无重名，顶层函数 0 重名；collect 的 re-export 与 `_DashedDropPainter` 改名完整，`BoxEditorMode`/`showBoxEditorDialog` 调用方零改动；wrongbook 5 个 part 接线完整，`_update` 转发 54 处（6+20+28）与 B4 文档一致，拆出文件内 `setState` 为 0，书脊负偏移/左暗带外移完整保留。`flutter analyze` 全量 0 问题；拆分验证组分 5 批跑完 45 个测试文件 **628/628 通过**（与 B3/B4 的全量数一致）；演示库 md5 未变。
- **路径安全（B3-P01）**：`resolveDataPath` 默认拒绝对路径，`allowAbsolute: true` 全仓只有测试用；`_deleteDataFileIfUnreferenced` 只接受 `slices/` 前缀；`_deleteTaskDirIfUnreferenced` 先验 taskId 安全字符集；备份路径校验与 zip-slip 校验均到位；`_resolveInsideDir` 越界返 null。
- **删题/删文件夹/删学科事务**：`_deleteQuestionTxn` 一次事务清错因记录、自查历史、任务指向、复习队列、框（含先删子框）、题行；`deleteFolderFromImpl` 整棵子树同事务，提交后才删无引用切片；`deleteSubjectFromImpl` 同事务删题/任务/文件夹/知识点/学科（仅 SR-P2-1 的草稿框缺口除外）。自查三步同事务；重框换框 + 切片同事务（仅 SR-P2-3 的写盘时序缺口除外）。
- **迁移/备份**：`migrateDataFiles` 复制→校验文件数/字节→`.old` 备份→同盘 rename→失败回滚；`_openDb` 只有主位置无库文件时才回退安装目录，已有库损坏时明确抛错不静默建空库；备份导出只打包被引用的文件；`exportBackupJsonFrom` 用 `jsonEncode`；恢复整个在事务内，失败不留半截库。JSON 多值字段收口完整，无裸 `join(',')`/`split(',')` 残留。
- **YOLO 只接第 1 层**：`intraEnabled = false`，`_detectIntra` 恒返回空；阈值 0.45、NMS 0.5；letterbox 与坐标换算正确（P05 像素差 0.0）；失败不回占位框；EXIF 手写解析、镜像方向显式失败；PDF 50MB/20 页上限与失败清理；旋转烘焙像素差 0.0；zip 校验与 14 张备份表；复查提醒四条件正确；主题/字体单次缩放；启动页白名单；左导航角标口径与 5 科上限；新学科同步导航。
- **真实题隐藏区域开关、叠加层真实框/回退、单框旋转禁用、左右键/滚轮、删除确认统一 AlertDialog、多页未框页保留、文件夹必填与学科隔离、详情页学科不可改/答案默认隐藏/删后进下一题/三段默认折叠**：收集组逐项核对无问题。行内确认条已无残留（详情 `_buildConfirmBox` 仅剩取消编辑三选一用途，不是删除确认，保留正确；“取消导入/取消排队”仍直接删，属取消进行中任务而非删除确认点）。
- **封面**：顶部无任何英文（`grep MATHEMATICS/ENGLISH/POLITICS/enName` 在错题本模块 0 命中）；书脊贴左边缘、通顶通底，左暗带随书脊外移、无旧位置残留暗带；样式与颜色两套独立系统（6 样式 × 7 色）；新学科封面默认灰色；三徽标始终显示（0 值也显示）；删除确认走模态弹窗（文件夹 13B 后果文案、批量删除、学科删除均核实）。
- **复习错因治疗模型**：手动“加入复习”才进列表；治愈判定走 `recordSelfCheck`（满 `cureChecks` 次，默认 2）；治愈后复查日 = 今天 + `recheckIntervalDays`（默认 7）；跳过按题×错因计次，第 1 次追加队尾、第 2 次留到下次（默认 2）；每批错因数默认不限；自查“不确定”不算；复查不过清零打回解决中；断点保存/恢复校验完整。
- **学习报告结构**：只答三个问题，无统计墙、无趋势线、无导出；时间范围默认本周、本周 = 周一到今天；薄弱 Top5 按关联题数降序、“看更多”展开全部；“接下来练什么”一句话、无按钮；空态完整。
- **设置默认值**与 `AppSettings.defaults`（`models.dart:537-572`）逐项一致：主题跟随系统、字体标准、问候“今天也要加油呀”、每页 10 条、错题本默认大卡片、复习默认按加入时间、提醒默认 20:00；设置页各分段改动均走 `_apply` → `onSettingsChanged` 保存，未见双写。
- **文档干净的部分**：README 依赖/schema/YOLO/备份；代码地图 §3 表与 JSON/备份/§8 YOLO；CODEBUDDY 的 YOLO/schema/演示库；decision-log 除 SR-P1-33～SR-P1-35、SR-P2-88 外的全部条目；边界文档 §4.5 复习全节与 §4.2/§4.3 的二层描述；四方分工的职责划分本身；B3/B4 汇总的拆分结构（行数已用 `wc -l` 核对，见 SR-P2-91 的 6 行差额）。

---

## 验证情况

- `flutter analyze`：拆分验证组全量跑过，**No issues found!（0 问题）**；各组分范围复跑亦均为 0 问题。
- 全量测试：拆分验证组分 5 批跑完 45 个测试文件，**628/628 通过**（146+148+141+83+110，与 B3/B4 的全量数一致），覆盖 database、collect、wrongbook 每个拆分文件。服务层组针对性单测 50/50 通过；收集组探针单测 2/2 通过后已删除探针文件。
- 演示库：各组跑测试前均备份到 `~/workspace/demo-db-backup/`，跑完核对 `~/.local/share/quiz-master2/quiz-master2.db` md5 均为 `8f7f9c64405dc6e484ac2bf8e5e1a807`（v1、9 题），未被改动。协调员收工时复核 md5 仍一致。
- 证据说明：SR-P0-2（错题本排序断言）的探针测试因同期并行测试占住构建缓存、8 分钟无输出而主动停掉，定论建立在代码链 + DropdownButton 契约上，修后须用单测复核。收集组一次 exec 返回 exit 2，报告中未说明原因，其探针结论为 2/2 通过。未跑 Linux Release 构建（B4-SUMMARY 称协调员已验证通过，本次未重复）。
- 本次自审未改任何代码，未 commit/push；新增文件只有 6 份分报告 + 本文件 + `SELF-REVIEW-SUMMARY.md`。

---

## 需 Meng 决定的事（共 12 项）

1. **SR-P0-3**：38MB 模型是否补 `.gitignore` 忽略规则（Batch 3 待定第 1 项）。
2. **SR-P2-25**：红色无框警告是否收窄到只对已检测过的任务显示（Batch 3 待定第 2 项）。
3. **SR-P0-2 修法**：设置项 `'subject'` 改为 `subj-asc`（或拆成两项），还是列表下拉补一个 `'subject'` 项。
4. **SR-P1-1 口径**：封面三数沿用首页互斥拆分，还是首页改双计。
5. **SR-P1-35**：D-06“继续上次优先级复习 > 整理 > 收集”是删规则（承认最后一次活动优先），还是改 `saveRecentTask` 实现优先级比较。
6. **SR-P2-38**：目录/封面题数扣掉已掌握（与列表默认视图同口径），还是保持含已掌握、提示改当前文件夹口径。
7. **SR-P2-49**：复习会话建块维持“每题带全部待治错因”（筛选只定起点），还是只取筛选命中的错因。
8. **SR-P2-58**：“重置”固定回时间新→旧，还是维持回设置默认值。
9. **SR-P2-85**：学科管理与设置算一个模块（加注解释）还是两个模块。
10. **SR-P2-73**：字号维持三档设置覆盖系统缩放，还是取 `max(设置档, 系统缩放)`。
11. **SR-P2-45(a)**：“最近一周”是 7 天含今天（现状 8 天）还是 7 天不含今天。
12. **SR-P2-36**：文件夹同名判重改为整科，还是改决定为只同层判重。

---

## 建议修补顺序

1. **先修 P0 三项**：SR-P0-1（孤儿误删页图）→ SR-P0-2（排序断言）→ SR-P0-3（.gitignore，等 Meng 一句话）。
2. **再修 P1 里“静默丢数据 / 静默覆盖”的**：SR-P1-5 + SR-P1-6（同一根因：编辑器内外 2 层框的键/分层口径不统一；修一处归一化函数，两处调用方都受益）→ SR-P1-7（队列打开前先保存）→ SR-P1-2（确认拆题事务扩到保留任务重建）→ SR-P1-4（_importPdf 写库进 try）→ SR-P1-3（deleteExam 包事务）→ SR-P1-8（重框隐藏缩略图条）→ SR-P1-14（图片 20MB 硬判）→ SR-P1-17（去重收进 enqueue）→ SR-P1-16（YOLO 加载失败不锁死）。
3. **再修 P1 计数/口径类**：SR-P1-1（封面三数，需先定口径）→ SR-P1-10 + SR-P1-11（报告计数）→ SR-P1-9（上次自查取 first）→ SR-P1-12（排序/页数只首次取默认）→ SR-P1-13（跳过收尾进 redo）→ SR-P1-15（CompactSliceThumb errorBuilder）。
4. **文档 P1 批量修**：SR-P1-18～SR-P1-24（边界 §4.2/§4.3，B3 遗留第 8 条本体）→ SR-P1-27～SR-P1-32（§5.1/§5.2/§5.3 确认状态、§2/§4.1/§4.4）→ SR-P1-33～SR-P1-39（decision-log 标注、四方分工基线、CODEBUDDY 与代码地图补 Batch 4）。
5. **P2 按“丢数据”优先**：SR-P2-18～SR-P2-20、SR-P2-22、SR-P2-24（2 层框相关）→ SR-P2-4～SR-P2-6（备份校验/恢复）→ SR-P2-8、SR-P2-10（非事务多步写）→ 其余 P2 与死代码随手清。
