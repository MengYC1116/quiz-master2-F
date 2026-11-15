# Batch 5 第五阶段 P2 文档修复报告（B5-P2-DOCS）

- 日期：2026-11-15
- 范围：最终自审文档 P2 15 项（SR-P2-71、SR-P2-78～SR-P2-90，另含第四阶段遗留的代码地图 §5 `_toRow` 注释）
- 分支：`ui-replication`；工作树 `~/workspace/quiz-master2-UI`
- 状态：**全部完成，未推代码，未 commit**
- 依据：`docs/ui-replication/SELF-REVIEW.md` 各节原文 + 逐条对照代码核对（`yolo_onnx_service.dart`、`box_editor.dart`、`wrongbook_list.dart`、`question_detail_page.dart`、`repository.dart`、`home_page.dart`、`models.dart`、`collect_page.dart`、`import_service.dart`、`design_tokens.dart`）
- 只改文档，不改产品代码；未跑全量测试（任务要求只 grep/读文件核对）；未碰演示库；未截图

## 逐项结果

### SR-P2-71 YOLO 报告过期 — `docs/ui-replication/YOLO-INTEGRATION-REPORT.md`

- §2：旧句“模型缺失、加载失败或图片文件不存在时回退占位（一页一个整题框）”→“返回空框 + `usedFallback: true`，不回占位框、不抛错”，并引 D-23 与 `DetectionResult` 注释（成功 `usedFallback` false，失败 boxes 为空、`usedFallback` true、`error` 为给用户看的原因）。核对：`lib/services/yolo_onnx_service.dart:11-16,44-45,130-131,144-173`。
- §4：两处前置限制的前提已过期，一并按现状重写（与“回占位”同一口径分裂，非扩范围）：
  - (1) “导入仍只存文件名、找不到回占位、文件落盘/PDF 渲染仍是待办”→导入已真实落盘（`imports/<task-id>/`，PDF 由 `pdf_render_service.dart` 按页渲成 `pages/`），找不到返回空框 + `usedFallback: true`。核对：`import_service.dart:14,20,43-64`。
  - (2) “修框画布仍是占位色块”→画布已是真实页图（`pageImagePath`），页图缺失时明确报错、不开编辑器。核对：`box_editor.dart:218`（“底图是真实页图，不再是占位纸面”）、`collect_page.dart:333-341`（§6 第 6 条守卫）。
- §6 与文首结论：测试数 388/388 → **674/674**（Batch 5 第四阶段结束时，2026-11-15；注“初版时为 388/388，随全量测试扩充而变”）。SELF-REVIEW 成文时写“现为 628”（Batch 4 结束数），本次按第四阶段已验证的最新数 674 更新。
- §8：(2)“Meng 需自己推这两个文件”→只推第 1 层一个文件（第 2 层已移出仓库、等训好后再说）；(3)“否则检测回占位”→返回空框（`usedFallback: true`），不回占位框；(4)“修框画布换真实页图（待办）”→已做，见 §4。
- 附：`yolo_onnx_service.dart` 行“占位回退保留”→“失败不回占位框（空框 + `usedFallback: true`）”。
- §4 首句“假检测（占位）换成了真实推理”未动：指 YOLO 接入前占位服务被真实推理取代，是历史事实，非现状口径。

### SR-P2-78 边界 §4.2 重叠措辞 — `docs/quiz-master2-mo-kuai-bian-jie-hua-fen.md`

- “框相互重叠时在确认时提示”→“框相互重叠时确认按钮禁用并行内警告（‘框重叠’——‘有框重叠了，请调开再确认’），调开后才能确认”。核对：`box_editor.dart:1050`（`confirmEnabled = total > 0 && !overlap && _pendingBox == null`）、`:1157-1160`（`QmBanner` 错误横条，文案逐字引用）。
- §4.2“不管什么”同款旧句“重叠只在确认时作一般提示”同步改：“框重叠时确认按钮直接禁用并行内警告（见上）”。

### SR-P2-79 边界 §4.4 大卡片容器 — 同上

- “最多一次性展示两道题，超过两道就在容器内用滚轮滚动”→“固定高度（466px）的容器，约展示 2.5 张卡（第三张露一半），超过就在容器内用滚轮滚动”。核对：`wrongbook_list.dart:687-700`（`>2 张卡：固定高度内部滚动容器（约 2.5 张卡，第三张露一半）`）、`design_tokens.dart:646`（`cardsScrollHeight = 466`）。

### SR-P2-80 边界 §4.4 筛选 — 同上

- “含试卷、错误类型、时间、复习状态、标签……”→“……时间、错因状态、标签……”。核对：`wrongbook_list.dart:285`（下拉名 `'错因状态'`，选项全部 / 待解决 / 解决中 / 已解决 / 复查）。

### SR-P2-81 边界 §5.1（现 §4.6）复习措辞 — 同上

- 原 §5.1 的“复习状态、已复习次数与下次复习时间”在第四阶段移入 §4.6 后写作“复习记录（各错因状态、解决次数与全部解决记录）”，本次补为“复习记录（各错因状态、解决次数、下次复查日与全部解决记录）”。核对：`question_detail_page.dart:17`（旧复习状态下拉与下次复习日期输入已删）、`:1587-1611`（每错因“下次复查 …”与“解决次数 ${record.solvedCount}”）。
- 与 SELF-REVIEW 修的方向有一处偏差（见遗留问题 1）：自审称“复习次数（`reviewCount`）仍保留显示”，但代码核对显示 `reviewCount` 只保留在模型与库里（`models.dart:310`、`db_codec.dart:72` 写回），没有任何页面渲染它（`grep -rn "\.reviewCount" lib/` 仅 demo_data 与编解码命中）。故边界文档未写“复习次数”，只写每错因的解决次数与下次复查日。

### SR-P2-82 边界 §3 计数自相矛盾 — 同上

- “共 8 个页面、9 条路由。已确认 7 个页面（7 行）；未确认 2 个页面（学科管理与设置是同一模块两条路由，所以在表中占两行）”→“共 8 个模块、9 个页面、9 条路由。已确认 7 个页面（7 行、7 个模块）；未确认 2 个页面、2 条路由、1 个模块（学科管理与设置是同一模块两条路由，所以在表中占两行）”。

### SR-P2-83 边界 §1/§3 “8 个页面” — 同上

- 文首标题“每个页面一个独立模块 · 8 个页面 / 9 条路由”→“每个页面一个独立模块 · 8 个模块 / 9 个页面 / 9 条路由”；§3 说明见 SR-P2-82。

### SR-P2-84 边界 §5.1 字号 — 同上

- “字号（标准 / 大，在设置内调整，首页不放字号开关）”→“字号（标准 / 大 / 特大，……）”。核对：`models.dart:540`（`standard / large / extraLarge`）、`:676-677`（三档字符串）。

### SR-P2-85 边界 §1/§5.3 同属一个模块 — 同上（已定决定 (a)）

- §1“页面即模块”句后加注：“‘模块’按业务归属计——学科管理与设置是两个独立页面、两条路由，但同属低频维护类、不参与收集 / 整理 / 复习的业务链，故合为一个模块；代码上 `lib/modules/subjects/` 与 `lib/modules/settings/` 各自独立，见 §5.1。”
- §5.1 首句补口径交叉引用：“合为一个模块（‘模块’的口径见 §1 注：两个独立页面、两条路由，合为一个模块）”。未改计数（§3 的 8 模块口径与此一致）。

### SR-P2-86 README “第 2 层已移除” — `README.md`

- 两处改“第 2 层已移除”→“第 2 层暂缓（`intraEnabled=false`，模型需重训；检测逻辑与数据模型保留，见 D-23）”。核对：`yolo_onnx_service.dart:67,244-274`（`_detectIntra`、后处理、`groupInners`、`QuestionBox.layer` 保留）与 D-23。

### SR-P2-87 README 结构树未列 B4 新增文件 — `README.md`

- `data/` 下补：Batch 4 拆分后 `database.dart` 只剩入口 + 10 个 part 文件（`db_backup / db_catalog / db_codec / db_collect / db_orphans / db_paths / db_questions / db_schema / db_settings / db_storage`，实现见代码地图 §2）。
- `modules/` 下补：Batch 4 拆分说明——collect/ 入口 + `box_editor.dart` + `collect_widgets.dart`；wrongbook/ 入口 + `wrongbook_shelf / wrongbook_directory / wrongbook_list / wrongbook_cover / wrongbook_widgets`。核对：`ls lib/data/db_*.dart`（10 个）、`lib/modules/collect/box_editor.dart`（2156 行）、`lib/modules/collect/collect_widgets.dart`（44 行）、`lib/modules/wrongbook/wrongbook_*.dart`（5 个）。

### SR-P2-88 decision-log D-06 — `docs/decision-log.md`

- 只改 D-06 条目（精确文本替换，未动其他条目；另一工人只在字号条目补记 SR-P2-73，未冲突）：“每科另三数：要复习 / 待复查 / 已解决（不显示总题数）”后加注：“三数指错题本封面徽章口径（`subjectCounts`，要复习 / 待复查 / 已解决）；首页学科格为要复习 / 待整理两数”。核对：`repository.dart:148-175`（`subjectCounts` 返回 `(toReview, toRecheck, solved)`）、`home_page.dart:12`（学科格“要复习 N 道 · 待整理 M 道”）。

### SR-P2-89 四方分工“眼前第一步” — `docs/四方分工.md`

- “Meng 先做 Win11 验收；Muse 和 CodeBuddy 待命；GPT 待命审验收结果。验收完按上面分流修，再跑一轮”→“最终自审已做完，第五批修复进行中；Meng 在自审汇总后决定是否推送代码。推送前 Muse 按自审分批修（P0 → P1 → P2 文档），CodeBuddy 与 GPT 待命：Win11 真机验收仍排在推送之后，按验收清单逐项验，验收出问题再按上面分流修。”并加括号注说明初版写于 2026-11-14 18:26、当时是验收前待命。基线行（628/628，Batch 4 结束时）未动——已注明“最新数以 B5-SUMMARY 为准”，是带日期的快照。

### SR-P2-90 代码地图 §5 — `docs/代码地图.md`

- §5 示例注释“`// lib/data/database.dart`，`_toRow`（节选）”→“`// lib/data/db_codec.dart`，`_toRow`（节选）”。核对：`db_codec.dart:63-68`（`_toRow` 现址）。
- 全文档重核：其余 `database.dart` 引用共 5 处（§2 表 :106、:172、:197、:207、:239、:694）均指入口/转发口径，仍正确——`AppDatabase` 仍在 `database.dart`，`backupTables` 仍在 `database.dart:113`（`db_backup.dart:20,55,110,116` 引用它）；全文无显式旧行号引用（`L148`/`L2152` 类写法 grep 为 0），无其他可改项。

## 改动文件（6 个，只改 docs）

| 文件 | 改动 |
|---|---|
| `docs/quiz-master2-mo-kuai-bian-jie-hua-fen.md` | SR-P2-78～SR-P2-85（8 处） |
| `docs/ui-replication/YOLO-INTEGRATION-REPORT.md` | SR-P2-71（§2、§4、§6、§8、附，6 处） |
| `README.md` | SR-P2-86（2 处）、SR-P2-87（2 处） |
| `docs/decision-log.md` | SR-P2-88（仅 D-06 一处） |
| `docs/四方分工.md` | SR-P2-89（眼前第一步一节） |
| `docs/代码地图.md` | SR-P2-90 + 第四阶段遗留（§5 注释 1 处） |

未改 `lib/*` 任何文件；未碰 git 历史，未 commit，未 push。

## grep 核对结果

- 边界文档旧表述 0 命中：`8 个页面`、`在确认时提示`、`最多一次性展示两道题`、`时间、复习状态`、`标准 / 大，`、`复习状态、已复习次数`、`未确认 3 个页面`、`重叠只在确认时`；新表述均已就位（`8 个模块 / 9 个页面`、`约展示 2.5 张卡`、`错因状态、标签`、`标准 / 大 / 特大`、`下次复查日与全部解决记录`、`按业务归属计`、`共 8 个模块`）。
- YOLO 报告旧表述 0 残留：`回退占位`、`回占位`、`占位回退保留`、`仍是占位色块`、`推这两个文件`、`388/388`（仅剩两处“初版时为 388/388”的历史注）；“不回占位框”4 处命中均为新写否定句，非残留；测试数两处均为 674/674。
- README：`第 2 层已移除` 0 命中，`第 2 层暂缓` 2 处；B4 文件清单已列入结构树。
- decision-log：D-06 加注已就位，其他条目未动。
- 四方分工：旧“眼前第一步”全文 0 命中（改写时未逐字引用旧句）。
- 代码地图：`database.dart，_toRow` 0 命中，`db_codec.dart，_toRow` 1 处。

## 遗留问题

1. **SR-P2-81 与代码的出入**：自审修的方向称“复习次数（`reviewCount`）仍保留显示”，但核对显示 `reviewCount` 只存于模型/库，从未在任何页面渲染（详情页只显示每错因的解决次数与下次复查日，错题本明确“不显示复习次数”）。本次按代码事实只写了每错因的解决次数与下次复查日，未写“复习次数”。若 Meng 认为题级复习次数应显示，需另立产品改动（不在文档范围）。
2. **未动项（不在本次 15 项内）**：边界 §4.4“不设序号”与大卡片左上角蓝色序号圆盘的关系（B5-DOCS-BOUNDARY 遗留 10 的观察，无自审编号，未改）；四方分工基线行仍为 628/628（Batch 4 结束快照，已注明以 B5-SUMMARY 为准）；YOLO 报告 §3 的 3 张页实测数据与 §7 再训练反馈是 2026-11-13 的实测记录，未动。
3. **共享文件**：`docs/decision-log.md` 另一工人（字号 SR-P2-73 补记）未见冲突——本次只做了 D-06 一处精确替换；若对方已改同一文件，以最终 `git diff` 为准复核。
