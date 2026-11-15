# 第二次自审：收集 / 整理 / 详情组（SELF-REVIEW-2-COLLECT）

- 时间：2026-11-15
- 工作树 `~/workspace/quiz-master2-UI`，分支 `ui-replication`；只审、不改代码；未提交、未推代码。
- 范围：`lib/modules/collect/collect_page.dart`、`lib/modules/collect/box_editor.dart`、`lib/modules/collect/collect_widgets.dart`、`lib/modules/organize/organize_page.dart`、`lib/modules/detail/question_detail_page.dart`、`lib/services/import_service.dart`、`lib/services/yolo_onnx_service.dart`、`lib/services/page_image_pipeline.dart`、`lib/services/pdf_render_service.dart`；另核对 `lib/widgets/widgets.dart` 的叠加层 / `QuestionSlice` 区域与 `lib/models/models.dart` 的 `newEntityId` / `allCauses`（Batch 5 动过这两处）。
- 对照基线：`docs/ui-replication/SELF-REVIEW.md`（SR-P1-2/4/5/6/7/8/14/16/17、SR-P2-3/18～35）与 Batch 5 报告（`B5-SUMMARY.md`、`B5-P1-DATA.md`、`B5-P1-256.md`、`B5-P1-7.md`、`B5-P1-8.md`、`B5-P1-4-14-17.md`、`B5-P1-16.md`、`B5-P2-COLLECT.md`）。
- 验证方法：读代码为主；写了 4 个临时探针测试验证关键结论，跑完已全部删除（工作树无残留，`git status test/` 与跑前一致）；针对性既有单测 7 个文件 169/169 通过；演示库全程 md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`（v1、9 题），跑前备份到 `~/workspace/demo-db-backup/quiz-master2.db.sr2-collect-before`，跑完恢复核对一致。
- 环境备注：本机 Flutter SDK 曾丢失（VM 替换），复用工作区已有的 `~/workspace/flutter-install/flutter`（3.47.9）跑通测试；`ldconfig` 后 clang 18.1.3 恢复可用。`~/workspace/flutter_linux_3.47.9-stable.tar.xz` 是本次误截断的旧残缺下载（完整包在 `flutter-install/` 内已有），已删除。

## 结论

- **问题总数：14 项（P1 5 项，P2 9 项）**，全部是 Batch 5 修复后仍存在的问题或 Batch 5 修复本身引入/遗留的缺口。
- 其中 4 项 P1 有临时探针测试实证（探针文件已删，复现要点见各条“证据”）：
  - SR2-COLLECT-1：确认拆题丢弃有框页上的独立题内框（P1-6 同类，B5 未覆盖）。
  - SR2-COLLECT-2：队列弹窗内连续两次批量操作，第二次用旧快照抹掉第一次的标签（P1-7 同类，B5 只修了打开时快照）。
  - SR2-COLLECT-3：`_saveCurrent` 不同步内存 `_queue`，切题往返后保存会覆盖已落盘的改动（B5-P1-7 报告自认的遗留，属实且可复现）。
  - SR2-COLLECT-4：`_failAndClean` 自身写库失败逃出 `enqueue`（P1-4 同类，B5 的两道防线只盖住一处调用点）。
- 其余 1 项 P1（SR2-COLLECT-5，图片分支尾部 upsert 在 try 外）与 9 项 P2 均为代码走读确认，附精确位置与触发路径。
- Batch 5 在本组范围的 P0/P1 修复本身没有发现“修错方向”的回归；SR-P1-5/6 的归一化单函数、SR-P1-2 的同事务保留任务、SR-P1-8 的缩略图条隐藏、SR-P1-14/16/17 均核实修到位（见文末“已核实干净”清单）。

---

## P1

### SR2-COLLECT-1（P1）：确认拆题丢弃有框页上的独立题内框

- 位置：`lib/modules/collect/collect_page.dart:599`（`_confirmSplit`）
- 现象：编辑器里可见、可拖、可删的独立题内框（`standaloneInner`，无父框的 stem/option/figure），只要它所在页有题级框、被确认拆题，就会静默消失：不挂到任何题、不进保留任务、原任务删除后无处可去，全程无提示。这与 B3 决定“手动 2 层框保留不动、不删数据”（SR-P1-6 引述）直接冲突，是 P1-6 同类的残留。
- 证据（探针 A 实证，已删）：
  - 草稿：`{b1: layer-1}` + `{orphan-stem: layer-2, 无 parentBoxId}` 同在第 1 页；打开编辑器，`stem 题干`可见；点“确认修框，去整理”，拆题成功。
  - 探针输出：`SR2-PROBE-A boxesByQuestionId ids: [b1]`——`orphan-stem` 不在任何题的框里。
  - 代码：`boxesByQuestionId[qid] = [box, ...?result.inners['$p:${box.id}']]` 只取有父框的内框；`result.standaloneInner` 在 `_confirmSplit` 里只在“未框页保留”分支出现（`retainedStandaloneInner`，:674），有框页的独立内框没有任何去向；`confirmSplitIntoImpl` 删原任务时随任务删掉全部未确认草稿框。
  - 独立内框的产生路径并不罕见：非内框模式下画 stem/option/figure 框、中心落在任何题级框外即进 `standaloneInner`（`box_editor.dart:968-984`）；YOLO 孤儿框与归一化后无主的旧框同样进这里。
- 修的方向：三选一并补测试——(a) 确认时把独立内框按中心点挂到最近/命中的题下（与 `_confirmPendingType` 的落点规则一致）；(b) 有独立内框时确认前弹提示，问用户丢弃或先挂到某题；(c) 至少把独立内框随保留任务保留（无未框页时无保留任务，此路不通，需另议）。测试应钉：有框页独立内框确认后仍在题的框里（B5 的 P1-6 测试只覆盖有父框的 `inners`，未覆盖此分支）。
- 严重度：P1（静默丢用户手画的数据）。

### SR2-COLLECT-2（P1）：队列弹窗内连续两次批量操作，第二次用旧快照抹掉第一次的改动

- 位置：`lib/modules/organize/organize_page.dart:2266-2273`（`_QueuePopupState._batchTagRedo`），对照 `:2283-2317`（`_batchAddFolder`）
- 现象：B5 的 P1-7 修复只保证了“打开队列时快照新鲜”，没保证“弹窗内连续批量操作之间快照新鲜”。`_batchAddFolder` 保存后用 `setState` 把新文件夹同步回弹窗内的 `_questions`，但 `_batchTagRedo` 保存后完全不更新 `_questions`。同一次弹窗内先点“批量打标签 #需重做”、再点“批量加入该文件夹”，第二次操作拿的仍是打标签前的旧 `Question` 做整行覆盖，标签被抹掉。
- 证据（探针 B 实证，已删）：三题仓库，选 q1 → 批量打标签 → 批量加入该文件夹（默认 f1）→ 关闭队列；探针输出：`SR2-PROBE-B q1 tags=[] folders=[f1]`。`_batchConfirm` 同样从 `_questions` 快照取行，先打标签再批量确认也会丢标签（同一根因）。
- 修的方向：`_batchTagRedo` 保存后同步更新 `_questions`（与 `_batchAddFolder` 同款 `setState` map），或批量操作前按 id 重读最新行再合并；测试应钉：同一弹窗内“打标签 → 加文件夹 → 关闭”后标签与文件夹都在（B5 的 P1-7 测试只做到单次批量操作 + 关闭）。
- 严重度：P1（P1-7 同类静默覆盖；用户在一次弹窗里连做两次批量操作是自然流程）。

### SR2-COLLECT-3（P1）：`_saveCurrent` 只写库、不同步内存 `_queue`，切题往返后保存会覆盖已落盘的改动

- 位置：`lib/modules/organize/organize_page.dart:313-320`（`_saveCurrent`）、`:326-332`（`_goTo`）、`:438-450`（`_jumpToQuestion`）、`:456-463`（`_applyQueueSort`）；表单读数：`:223-257`（`_loadForm` 读 `_current` 即 `_queue[_index]`）
- 现象：B5-P1-7 报告末尾自认的遗留，属实且可复现。`_saveCurrent` 只写库，`_queue` 里仍是旧对象；`_goTo` / `_jumpToQuestion` / `_applyQueueSort` 保存后都不刷新 `_queue` 就调 `_loadForm`。改 q1 文件夹与答案 → 切到下一道（已落盘）→ 切回来，表单从 `_queue` 读出旧值；此时点“保存草稿”，`_formQuestion` 按旧表单 state 整行写回，把已落盘的文件夹与答案覆盖回旧值。
- 证据（探针 D 实证，已删）：先切题，`repo.saved` 里 q1 已有 `f2` 与 `答案：1`（第一次保存成功）；切回来点“保存草稿”，探针输出：`SR2-PROBE-D lastSave folders=[] answer=null`。B5 只在 `_openQueue` 里单点打补丁（把表单行写回 `_queue`），其余三条切题路径仍是旧形状。
- 修的方向：按 B5-P1-7 报告自己建议的根治方案——在 `_saveCurrent` 内统一把保存后的行写回 `_queue`（或切题时 `_refresh`）；测试应钉：改表单 → 下一道 → 上一道 → 保存草稿，文件夹与答案仍在。
- 严重度：P1（静默覆盖已保存的改动，与 P1-7 同级；触发只需一次切题往返）。

### SR2-COLLECT-4（P1）：`_failAndClean` 自身写库失败会逃出 `enqueue`，任务卡 importing、整批中断

- 位置：`lib/services/import_service.dart:463-476`（`_failAndClean` 内 `await _db.upsertCollectTask(failed)` 无 try）；调用点 `:380-392`（读页数/判页数失败）、`:406`（超空间）、`:424-430`（渲染失败）；`enqueue` 的 PDF 分支 `:283-297` 对 `await _importPdf(...)` 无 try。
- 现象：B5 的 P1-4 修复只盖住了 `_importPdf` 尾部 upsert 这一处调用点（`:449-460`，失败走 `_failAndClean`、再失败返回内存 failed 任务）。其余 6 处 `_failAndClean` 调用点都在 try 保护之外：写库恰好在此时失败（磁盘满、库锁、DB 损坏），`_failAndClean` 内的 upsert 抛错 → 逃出 `_importPdf` → 逃出 `enqueue` → 任务卡 `importing`、同批后面的文件不再处理。与 SR-P1-4 修前的失败模式完全相同。
- 证据（探针 C 实证，已删）：内存库建触发器，凡 `status='failed'` 的 UPDATE 一律 `RAISE(ABORT)`；损坏 PDF（open 即抛 `PdfCorruptException`）进 `_importPdf` → `_failAndClean` → 触发器炸 → `enqueue` 抛出 `DatabaseException`（日志含 `UPDATE collect_tasks ... status = ?, ... failed ...`），探针 `expect(caught, isNull)` 失败。
- 修的方向：在 `_failAndClean` 内给 upsert 包 try/catch，失败返回内存里的 failed 任务（与尾部调用点的处理同款，一处修、六处受益）；或在 `enqueue` 按文件包 try，把异常转成该任务的 failed 行并继续下一文件。测试应钉：`_failAndClean` 写库失败时 `enqueue` 不抛、整批继续（B5 的 P1-4 测试只钉了尾部 upsert 失败）。
- 严重度：P1（与 SR-P1-4 同级同类；触发概率低，但失败模式是“卡死 + 整批中断”）。

### SR2-COLLECT-5（P1）：图片分支尾部 upsert 在 try 外；其余失败分支的 upsert 同款残留

- 位置：`lib/services/import_service.dart:359`（图片分支末尾 `await _db.upsertCollectTask(task)`，即 needBox 收尾）；另 `:227`（超限失败）、`:237`（超空间失败）、`:279`（复制失败）、`:294/:313/:327`（EXIF/解码失败各分支）。
- 现象：与 SR-P1-4 修前的 PDF 路径完全同款，图片路径没修——写库失败时异常逃出 `enqueue`，任务卡 `importing`、整批中断。B5-P1-4-14-17 报告遗留第 2 条自认“图片分支末尾的 upsert 与修前的 PDF 同款形状（在 try 之外），本次未动”。
- 另两处同款亚型（代码走读确认，未探针）：
  - (a) `:227/:237` 的失败 upsert 藏在 `try { ... } catch (_) {}` 里：upsert 抛错会被空 catch 吞掉，库里任务仍停在 `importing`，但内存返回的任务却是 failed——库与返回结果不一致，收集页 `_load` 读库后任务仍显示“导入中”，无法重试。
  - (b) `:294/:313` 的 EXIF 失败分支：`canDecodeImageBytes` 为假时先删目录、再 `_failed`、再 upsert；若这次 upsert 抛错，控制流落入外层 `catch (e)`（`:336` 起），被当成“读盘/写盘等不明确的原因”走降级兜底，继续往下把任务写成 needBox——目录已被删、页图不存在，任务变成“待框选但打不开”（`_openBoxEditor` 会因页图缺失拒绝）。降级注释称“走到这里的不是解码失败”，对这一子路径是错的。
- 修的方向：图片尾部 upsert 与 P1-4 同款包进 try/catch 走 `_failAndClean`；超限/超空间/复制/EXIF 各失败分支的 upsert 各自包 try，失败只返回内存 failed 任务；EXIF 分支把“已判定解不开图片”（目录已删）与“读盘/写盘失败”（原图还在）分开处理，前者失败后不得复活成 needBox。
- 严重度：P1（(a)(b) 为 P2 亚型，但主项图片尾部 upsert 与 SR-P1-4 同级）。

---

## P2

### SR2-COLLECT-6（P2）：重框“恢复自动框”只认第一道题级框，`reworkQuestionId` 的比较永假

- 位置：`lib/modules/collect/box_editor.dart:703-711`（`_restoreAutoBoxForRework`）
- 现象：`final target = layer1.firstWhere((b) => targetId == null || b.id == targetId, orElse: () => layer1.first)`，其中 `targetId = widget.reworkQuestionId`，详情页传的是题 id（`question_detail_page.dart:330` 的 `reworkQuestionId: q.id`），永不等于框 id。于是单框题靠 `orElse` 兜底恰好正确，多框题（重框允许一题多个 1 层框，见 SR-P2-23 讨论）永远只对第一道框做 IoU 匹配与替换、只跟随其内框；若检测框实际对应的是第二道框，IoU 对第一道框算出来 ≤0.05，还会误报“没找到对应的题，请手动框选”，或把第一道框挪到第二道题的位置上、与第二道框重叠导致确认被重叠校验拦下。
- 证据：代码走读；B5 的 P2-20 测试只用单 1 层框（`initialBoxesByPage: {2: [_box(id: 'q1-box', ...)]}`），`reworkQuestionId: 'q1'` 与框 id 的死比较被单框掩盖。
- 修的方向：按题意逐个目标框做 IoU 匹配替换（或在重框入口限制一题一框并写明）；测试补多框用例：两道 1 层框 + 各挂内框，恢复后两道框各就其位、内框各自跟随。
- 严重度：P2（单框题不受影响；多框题是允许态）。

### SR2-COLLECT-7（P2）：“恢复自动框”的手动判断查了全部页，当前页无手画框也会误弹确认

- 位置：`lib/modules/collect/box_editor.dart:650-658`（`_restoreAutoBoxes`）
- 现象：B5 修 SR-P2-19 时把 `hasManual` 从“只查 1 层框”扩到 `_inners.values.any(hasManualIn) || _standaloneInner.values.any(hasManualIn)`，但 `_inners` / `_standaloneInner` 是跨页的 map，`_boxes` 却只是当前页。当前页只有 YOLO 框、别页有手画框时，点“恢复自动框”也会弹“用自动框替换当前页的手动框？”，而确认后 `_ingestDetected` 只替换当前页——对话框的文案（“当前页的框会被替换，手动改过的框就没了”）与实际行为不符，属于误弹。
- 证据：代码走读；B5 的 P2-19 测试只覆盖“当页手画独立框弹确认 / 纯 YOLO 页不弹”，未覆盖“手画框在别页”的对照。
- 修的方向：`hasManual` 只查当前页：`_boxes` + `_inners` 中 `'$page:'` 前缀的键 + `_standaloneInner[page]`。
- 严重度：P2（只多一次确认弹窗，不丢数据）。

### SR2-COLLECT-8（P2）：`_hasSplitSibling` 是派生信号而非持久化信号，删拆分任务行后保留任务的警告消失

- 位置：`lib/modules/collect/collect_page.dart:117-125`（字段注释称“补信号”）、`:145-160`（`_load` 内由现存拆分任务行派生）、`:1147-1152`（`_taskRow` 的 `warnUnboxed`）
- 现象：B5 称 `_hasSplitSibling` 是“持久化信号”，实际每次 `_load` 由当前任务表重新派生，没有任何字段落盘。保留任务（P1-2 重建回 needBox、未框页无草稿）之所以警告，全靠同源拆分任务行还活着。用户在收集页删掉全部同源拆分任务行（待整理行上的“删除”允许删，见 `_deleteTask`），下次 `_load` 该信号即消失，保留任务不再警告——它确实打开并确认过，警告本应继续。
- 证据：代码走读；反向确认：新建任务、取消导入、删除任务后无残留（派生计算每次重算，这半边是对的）；`_hasSplitSibling` 无任何写盘路径（全仓 grep 无写操作，只有 `_load` 内赋值）。B5 的 P2-25 测试只覆盖新导入/修框中/有草稿三任务，未覆盖“拆分兄弟被删”的保留任务。
- 修的方向：任务行加持久化“已打开过修框”标志（`_openBoxEditor` 置 boxing 时已落盘，可直接用状态；保留任务重建时把该标志带上），或删拆分任务时不同步影响保留任务的警告判断。
- 严重度：P2（只影响一行警告文案的显隐，不影响流程）。

### SR2-COLLECT-9（P2）：`allCauses` 不去重，旧数据同名自定义仍在详情页与错题本重复显示

- 位置：`lib/models/models.dart:345`（`List<String> get allCauses => [...errorTypes, ...customErrorTypes]`）
- 现象：B5 的 P2-27 只堵了新入口（新建自定义拦同名）与整理/详情编辑时的读入+保存合并；未重保存过的旧题，库里仍有固定名自定义。详情页信息区 `q.allCauses.join('、')`（`question_detail_page.dart:1272-1274`）会显示“其他、其他”；错题本紧凑行 `_causeStatusesOf`（`wrongbook_page.dart:434`，无记录时按 `allCauses` 逐条出 pill）同样重复；详情复习记录区按 `allCauses` 逐条出行的几处（`:1039-1040`、`:1636`、`:1766`）亦然。报告 Top5 不受影响（按题 id 集合计数，`report_page.dart:195-211`），`syncCauseRecords` 内部用 `toSet` 去重亦不受影响——纯显示重复。
- 证据：代码走读；`allCauses` 全仓 20+ 处消费，均直接读库对象，不经过整理/详情的合并逻辑。
- 修的方向：在 `allCauses` getter 内保序去重（`{...errorTypes, ...customErrorTypes}.toList()`），一处修、全链路受益；或入库时迁移旧数据。
- 严重度：P2（仅旧数据显示重复；新数据已无法产生）。

### SR2-COLLECT-10（P2）：`realRegionRects` 跨父框比切片面积，获胜内框可能不属于切片来源的框

- 位置：`lib/widgets/widgets.dart:84-118`（`realRegionRects`）
- 现象：B5 的 P2-24 b 方案“面积最大者胜”比较的是换算后（切片坐标 0..1）的面积；不同父框下的内框在切片坐标系下面积不可比——小父框下的小内框换算后可能比大父框下的大内框“更大”。更关键的是切片归属：题的切片只按首个 1 层框裁出（确认拆题每题取其第一个 1 层框裁剪），而 `realRegionRects` 对每个内框按其各自 `parentBoxId` 换算、再跨父框取胜；获胜内框若挂在非首个父框下，画在首个框的切片上位置是错的。
- 证据：代码走读；`layer2BoxToSliceRect(parent ?? firstLayer1, b)` 的换算基准是各自父框，`out[b.type]` 的胜负比较不带父框信息。
- 修的方向：只取切片来源父框（首个 1 层框）下的内框参与比较，或按页图坐标面积比较；测试补“两父框同区域内框，胜者应为切片来源父框下的那一个”。
- 严重度：P2（仅多 1 层框的题会触发；单框题不受影响）。

### SR2-COLLECT-11（P2）：`_confirmSplit` 成功后 `saveRecentTask` 在 try 外，失败时拆题已提交但无反馈、列表不刷新

- 位置：`lib/modules/collect/collect_page.dart:687-695`（`_confirmSplit` 尾部）
- 现象：`confirmSplit` 事务成功后，`await widget.repo.saveRecentTask(...)` 无任何 try；写库失败时异常抛到 `_openBoxEditor`（同样无 try），进而成为未处理的异步异常：成功提示不弹、尾部的 `_load()` 不执行，列表停留在拆题前的旧态（任务仍显示待框选），用户须手动切页/重进才刷新。拆题本身已提交，无数据丢失。
- 证据：代码走读；与 SR-P1-4 同类“事务后收尾写库无保护”，只是影响面小（仅最近任务记录 + 列表刷新）。
- 修的方向：收尾包 try/catch，失败记日志或忽略，不影响“已生成 N 道题”的成功提示与 `_load()`。
- 严重度：P2。

### SR2-COLLECT-12（P2）：`_openQueue` / `_goTo` / `_jumpToQuestion` / `_applyQueueSort` 的 `_saveCurrent` 无 try，保存失败时队列打不开且无提示

- 位置：`lib/modules/organize/organize_page.dart:372-376`（`_openQueue`）、`:326-332`（`_goTo`）、`:438-450`（`_jumpToQuestion`）、`:456-463`（`_applyQueueSort`）
- 现象：B5 的 P1-7 把 `_openQueue` 改成异步并在弹层前 `await _saveCurrent()`，但保存失败时异常直接逃出 `onTap`（`InkWell.onTap` 是 `void Function()?`，异步异常无人接）：队列打不开、没有任何提示。修前同步版至少能打开队列。`_goTo` / `_jumpToQuestion` / `_applyQueueSort` 同款。
- 证据：代码走读；四处均无 try/catch，`_saveCurrent` 内 `repo.save` 与 `syncCauseRecords` 均可抛错。
- 修的方向：保存包 try，失败弹提示后仍允许打开队列/切题（表单改动留在内存里，用户可重试保存），或明确拦下并提示原因。
- 严重度：P2（仅写库失败时触发；但 P1-7 的修法把“保存失败 = 队列打不开”变成了新行为）。

### SR2-COLLECT-13（P2）：`boxesForPageImageFromImpl` 仍无 `ORDER BY`，P2-24 的 a 方案未落实

- 位置：`lib/data/db_collect.dart:221-237`（`boxesForPageImageFromImpl`，两次 `db.query` 均无 `orderBy`）；对照 `:199`（`boxesForTask` 有 `orderBy: 'page ASC, id ASC'`）
- 现象：B5-P2-COLLECT §7 转交数据层工人的第 1 项，至今未落实。`realRegionRects` 的“同面积取第一个”依赖输入列表顺序，而输入顺序即库返回行序（无 ORDER BY 时通常是 rowid 序，但 SQLite 不保证）。B5 的 b 方案（面积最大优先）已实现，面积不等时已确定；面积相等时仍不确定。
- 证据：代码走读；全仓 `orderBy` 检索：`db_collect.dart` 仅 `:10` 与 `:199` 两处有，`boxesForPageImageFromImpl` 不在其中。
- 修的方向：按转交项补 `ORDER BY page ASC, id ASC`（与 `boxesForTask` 对齐）；本组文件外，属数据层工人范围。
- 严重度：P2（仅同区域同面积的并列情况受影响；实践中 rowid 序稳定）。

### SR2-COLLECT-14（P2）：详情重框事务失败会毁掉旧切片（SR-P2-3 的取舍未定）

- 位置：`lib/modules/detail/question_detail_page.dart:347-366`（`_reworkBoxes`：先写盘再落库）
- 现象：B5 的 P2-3 修复是“事务失败即删刚写的切片文件”，但切片路径按题 id 固定（`ImportService.sliceRelative(q.id)`），写盘那一刻旧切片字节已被覆盖；事务失败后删文件，题连旧切片也没了，暂无切片、须再次重框才能恢复。B5-P2-COLLECT §5 自认此取舍（“如需‘失败恢复旧切片字节’，可改为写盘前先读旧字节、失败时写回——协调员定夺”）。
- 证据：代码走读 + 测试缺口：B5 的 P2-3 回归测试夹具里 `slices/q1.png` 事先不存在（只断言“新切片已删、框与题不动”），未覆盖“有旧切片”的真实情况，旧切片被毁的行为未被任何测试钉住。
- 修的方向：写盘前先读旧切片字节、失败时写回；或先写临时名、事务成功后再改名（与 SR-P2-3 原报告建议一致）；由协调员定。
- 严重度：P2（事务失败本身是低概率；但一旦发生，旧图不可恢复，只能重框）。

---

## 新测试质量（只测 happy path 的缺口）

以下新增 / 改动测试只覆盖了主路径或对照组，未钉住对应修复的负向 / 边界行为（与上面问题编号对应）：

| 测试文件与用例 | 缺口 |
|---|---|
| `test/import_service_p1_fixes_test.dart`：SR-P1-14 组（21MB 失败 / 小图对照） | 未测恰好 20MB 边界（`size > limit` 为假应放行）；未测 PDF 50MB 边界。 |
| 同上：SR-P1-17 组（同路径两次 / 两不同文件 / 跨批） | 只测同一路径字符串；同文件不同写法（大小写、符号链接、相对路径）未测。 |
| 同上：SR-P1-4 组（尾部 upsert 失败） | 只测尾部 upsert 失败；`_failAndClean` 自身写库失败未测（SR2-COLLECT-4 的缺口）。 |
| `test/b5_p1_256_test.dart`：SR-P1-6 widget（确认后 stem 在 `inners` 不丢弃；可拖动/删除） | 只测有父框的 `inners`；独立题内框（`standaloneInner`）确认后去向未测（SR2-COLLECT-1 的缺口）。 |
| 同上：SR-P1-2 DB 测试（保留任务 + 未框页草稿） | 只测有未框页草稿的保留；独立内框在保留任务中的去向未测（同上）。 |
| `test/b5_p2_collect_test.dart`：SR-P2-20（内框跟随 + 钳制） | 只用单 1 层框；多框题的恢复目标选择未测（SR2-COLLECT-6 的缺口）。 |
| 同上：SR-P2-19（当页手画独立框弹确认 / 纯 YOLO 不弹） | 未测“手画框在别页”的对照（SR2-COLLECT-7 的缺口）。 |
| 同上：SR-P2-25（三任务对照） | 未测“拆分兄弟被删后保留任务警告消失”（SR2-COLLECT-8 的缺口）。 |
| 同上：SR-P2-3（事务失败删新切片） | 夹具无预存切片，未钉“旧切片被覆盖后事务失败、题暂无切片”（SR2-COLLECT-14 的缺口）。 |
| 同上：SR-P2-24（同面积取第一个） | 只测列表内顺序；库返回行序未定（SR2-COLLECT-13 的缺口，ORDER BY 未落实）。 |
| `test/organize_page_test.dart`：SR-P1-7 组（打开前保存 + 单次批量打标签/确认） | 未测同一弹窗内连续两次批量操作（SR2-COLLECT-2 的缺口）；未测切题往返后再保存（SR2-COLLECT-3 的缺口）。 |
| `test/yolo_onnx_service_test.dart`：SR-P1-16（失败 → 恢复 → 缓存复用） | 三段式本身是好的负向测试；缺口：并发检测共用 `_loadFuture` 未测；无 onnxruntime 原生库时 `markTestSkipped` 使关键断言空跑（环境依赖）。 |
| `test/detail_page_test.dart`：SR-P1-8（源页 ≥2 无缩略图条） | 单测覆盖到位；缩略图条已隐藏、切页不可达，无需额外负向。 |

肯定部分：B5 新增测试的负向覆盖整体是好的——P2-22 两种失败清理、P1-4 触发器模拟写库失败、P2-19 取消/替换双路径、P2-25 三任务对照、P1-7 反向验证（临时去掉修复后 3 个新测试全失败），均不是只测 happy path。

---

## B5-SUMMARY 遗留项逐项确认（任务第 4 项）

| 遗留项 | 是否属实 | 是否影响使用 |
|---|---|---|
| 收集工人转交：`db_collect.dart` 加 `ORDER BY` | 属实，未落实 | 轻微（仅同区域同面积并列时行序不确定）→ SR2-COLLECT-13 |
| 收集工人转交：uikit 过期注释 | 属实，`lib/widgets/uikit.dart:551/585/1662` 仍提及已删的 `InfoChip` / `DashedDivider` | 不影响使用，纯注释（另 `test/widgets_forward_test.dart:3` 有一句说明注释，属实且无害） |
| `QuestionSlice` failed 分支的 FittedBox 遗留 | 属实，`lib/widgets/widgets.dart:301-340` 的 failed 分支 Column（自然高约 110px）未包 `FittedBox.scaleDown`，而 `_missingImagePlaceholder`（`:362`）已包 | 当前无影响：唯一 `failed: true` 调用在详情页 `maxHeight: 320`（`question_detail_page.dart:850-856`）；仅将来窄卡片复用时有溢出风险 |
| SR-P2-3 失败后题暂无切片的取舍 | 属实（见上） | 低概率下丢旧切片字节，需再次重框恢复 → SR2-COLLECT-14，需协调员定夺 |
| `_saveCurrent` 不同步内存队列 | 属实，且探针 D 已证实往返覆盖 | 影响使用 → SR2-COLLECT-3（P1） |
| 图片分支尾部 upsert 在 try 外 | 属实 | 影响使用（与 P1-4 同级）→ SR2-COLLECT-5（P1） |
| `box_editor.dart` 页图无 `errorBuilder` | 属实，`box_editor.dart:1585` 的 `Image.file` 无 `errorBuilder` | 极小：`_loadPageImageSize` 的 `_pageImageFailed` 门控（`:424-444`）覆盖绝大多数情况；仅首帧（异步解码完成前）损坏页图会短暂闪现空白/报错，随即被占位文案替换 |

另两项 B5 自认的相邻遗留一并核实：
- `saveDraftBoxesIntoImpl` 只取 `boxesByPage` 里 1 层父框的 `inners`（`db_collect.dart:264-279` 的 `flat` 构造）：属实，但当前链路不受影响——编辑器内 `inners` 恒挂在 live 父框下（删父框会清内框，`_deleteSelected`），且 P1-2 的事务内写回已绕开它按 key 页码全量取；属潜在契约缺口，不列为问题。
- 批量操作真事务（B5-SUMMARY “另立项”）：属实，页内批量仍是逐项 `save`（`organize_page.dart:2266-2375`），中途失败会留部分已改、部分未改；超出本次收集组范围，记一笔，不编号。

---

## 已核实干净（逐项一句话）

- **SR-P1-5 / SR-P1-6（归一化单函数）**：`normalizeBoxEditorInputs`（`box_editor.dart:120-192`）裸键补前缀、混层拆分、重复去重、`parentBoxId` 对齐均已实现，详情页与收集页两处调用方一字未动、共走同一入口；`_currentDraft`（`:461-480`）输出侧对齐 `parentBoxId`；`initState`（`:393-414`）与 `_autoDetectIfEmpty`（`:606-626`）的“有草稿”判断均按 1 层 + 内框 + 独立框三处算，无把内框坐标算错的分支（相对位置换算只在 `_restoreAutoBoxForRework`，见下）。
- **SR-P1-2（确认拆题同事务）**：调用方 `_confirmSplit`（`collect_page.dart:631-690`）确认前构造保留任务与未框页草稿、随 `confirmSplit` 一起提交，事务外两步重建已删；数据层 `confirmSplitIntoImpl` 同事务先删原任务、后插保留任务（同 id），未框页内框按 key 页码全量取；既有 P1-2 widget 测试断言“同一次调用提交”与保留任务警告均通过（本次针对性回归 169/169 含该组）。
- **SR-P1-7（打开队列先保存，打开时部分）**：`_openQueue`（`organize_page.dart:372-396`）先 `await _saveCurrent()`、再把表单行写回 `_queue`、再拍快照；保存中二次点开有二次 guard；既有 3 个新测试通过（但弹窗内连续批量与切题往返仍有缺口，见 SR2-COLLECT-2/3）。
- **SR-P1-8（重框缩略图条）**：重框模式 `_thumbStrip` 整体不渲染（`box_editor.dart:1299` 附近条件），标题显示真实源页码，确认只读 `result.boxesByPage[sourcePage]`；`_switchPage` 在重框模式下无 UI 可达入口。
- **SR-P1-4（PDF 收尾写库）**：`_importPdf` 尾部 upsert 已包 try/catch 走 `_failAndClean`，`enqueue` 调用点后收尾 upsert 也有兜底；触发器模拟测试通过（但 `_failAndClean` 自身无保护，见 SR2-COLLECT-4）。
- **SR-P1-14（图片 20MB 硬判）**：`enqueue` 复制前统一判 PDF 50MB / 图片 20MB，超限直接进 failed、不复制；`oversizeHint` 与收集页横幅文案已同步为“导入会失败”。
- **SR-P1-17（同批去重）**：`seenPaths` 边建边更新，同批重复只建一个任务；跨批有意放行（D-08）且测试锁定；`duplicate` 空分支与 `existing` 快照已删。
- **SR-P1-16（YOLO 失败可重试）**：`_loadAttempted` 已删，`_ensureLoaded`（`yolo_onnx_service.dart:192-200`）失败清 `_loadFuture`、下次检测重试，失败时 `_questionSession` 置空（`_loadOnce` 的 catch），成功后 `_loadOk` 缓存复用，并发共用一次加载；三段式回归测试通过。
- **SR-P2-18**：首页面与切页门控均按三处算，只有独立内框的页不重检测（测试覆盖切走再回来）。
- **SR-P2-19**：`_restoreAutoBoxes` 的 `hasManual` 查 `_inners` 与 `_standaloneInner` 的 `origin == 'manual'`（但范围跨页，见 SR2-COLLECT-7）。
- **SR-P2-20**：重框恢复后内框按新旧框相对位置等比跟随、再 `_clampInner` 钳进新框，旧框无面积时只钳制（但只对第一道 1 层框，见 SR2-COLLECT-6）。
- **SR-P2-21**：祖先 `Listener.onPointerDown` 鼠标左键点画布空白退出内框模式，点框/缩放柄仍是拖动。
- **SR-P2-22**：`writtenRels` 清单先记后写（旋转为 0 时不记原页图），裁剪失败与事务失败两处都按清单删文件；保留任务重建已由 P1-2 事务化。
- **SR-P2-23**：`realRegionRects` 按 `parentBoxId` 归属到各自 1 层框换算，老数据（`parentBoxId` 为空）回退首个 1 层框（跨父框面积比较见 SR2-COLLECT-10）。
- **SR-P2-24**：面积最大优先、同面积取列表第一个已实现并测试（ORDER BY 未落实见 SR2-COLLECT-13）。
- **SR-P2-25**：警告收窄到 `boxing` / 有任意草稿 / 有拆分兄弟三信号，新导入任务不警告（派生信号可丢见 SR2-COLLECT-8）。
- **SR-P2-26**：详情新建文件夹 `SimpleDialog` 有“取消”项，返回值 `'top'` / `''` / `null` 区分顶层、取消、框外关闭，后两者都不建。
- **SR-P2-27**：新建自定义拦同名（直接选中固定项 + 提示），整理页 `_loadForm` / `_formQuestion` 与详情页 `_beginEdit` / `_saveEdit` 均合并旧数据同名项（旧数据读路径仍有重复显示，见 SR2-COLLECT-9）。
- **SR-P2-28**：新建文件夹/试卷/知识点与 `_failTask` 全走 `newEntityId`（毫秒 + 8 位随机 hex）；拆题 id 补 6 位随机段；`collect_page.dart:501` 的 `import-/task-` id 含页与序号且已补随机段。
- **SR-P2-29**：整理页修框切片整题卡与纸面图均传 `subject: _subjectOf(q.subjectId)`；缺图占位已包 `FittedBox.scaleDown`。
- **SR-P2-30**：`_donePages` 行为未变，只改文案说明其为本次打开的装饰标记。
- **SR-P2-31**：切页（`_switchPage`）与取消按钮的保存草稿均包 try/catch，失败提示且不拦切页、不困住用户。
- **SR-P2-32**：`box_editor.dart` 6 处硬查已换 `_layer1ById` 可空守卫；其余 in-scope 文件的 `firstWhere` 均有 `orElse`，仅 `organize_page.dart:2281`（`_batchAddFolder` 查 `_folders`）一处无 `orElse`，但弹窗内文件夹列表无删除路径、UI 不可达。
- **SR-P2-33**：`CollectStatus.done` 全仓无赋值处，分支为防御保留并已加注释。
- **SR-P2-34**：`DashedDivider` 与 `InfoChip` 已删，`lib/` 内零引用（仅 `uikit.dart` 三处过期注释，见遗留确认表）。
- **SR-P2-35**：`_subjectInitial` 与 `_dateText` 已抽文件级共用（`organize_page.dart:17-25`），队列弹窗详情行日期零补齐。
- **SR-P2-36**：整理页与详情页新建文件夹均有整科同名预检 + `StateError` 兜底。
- **SR-P2-3（修复部分）**：详情重框事务失败删新切片并提示（旧切片被覆盖的取舍见 SR2-COLLECT-14）。
- **SR-P2-60**：拆题 id 补 6 位随机段，测试锁定成功确认的 id 格式。
- **图片链路服务（`page_image_pipeline.dart` / `pdf_render_service.dart`）**：`rotateBoxToRotatedPage` 四角度换算与钳制（区间求交）正确，字段（`parentBoxId` / `page` / `questionId` 等）原样保留；PDF 引擎异常分层（加密/损坏/渲染失败）完整，未发现 Batch 5 引入的新问题。
- **`collect_widgets.dart`**：仅 `DashedDropPainter`，无行为改动。

## 验证记录

- 针对性单测（`~/workspace/flutter-install/flutter/bin/flutter test`，`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`）：`test/b5_p1_256_test.dart`、`test/b5_p2_collect_test.dart`、`test/import_service_p1_fixes_test.dart`、`test/yolo_onnx_service_test.dart`、`test/collect_page_test.dart`、`test/organize_page_test.dart`、`test/detail_page_test.dart`——**169/169 通过**。
- 临时探针（已全部删除，无残留）：探针 A（独立内框确认丢失）与探针 B（弹窗内连续批量丢标签）与探针 D（切题往返覆盖）与探针 C（`_failAndClean` 写库失败逃出 `enqueue`）均按预期失败，证实对应问题；探针文件 `test/sr2_probe_ui_test.dart`、`test/sr2_probe_import_test.dart`、`test/sr2_probe_goto_test.dart` 已删，`git status test/` 与跑前一致。
- 演示库：跑前备份 `~/workspace/demo-db-backup/quiz-master2.db.sr2-collect-before`，跑完 md5 仍为 `8f7f9c64405dc6e484ac2bf8e5e1a807`，与备份一致。
- 未跑全量测试（本次任务只要求针对性单测）；`flutter analyze` 未跑（本次只审不改，B5 阶段已报 0 问题）。
