# quiz-master2 第二次自审 · 文档组报告（SELF-REVIEW-2-DOCS）

- 日期：2026-11-15
- 工作树：`~/workspace/quiz-master2-UI`，分支 `ui-replication`
- 范围：`docs/quiz-master2-mo-kuai-bian-jie-hua-fen.md`、`docs/decision-log.md`、`docs/CODEBUDDY.md`、`docs/代码地图.md`、`docs/四方分工.md`、`README.md`、`docs/ui-replication/` 下的 B5 报告与 SELF-REVIEW 系列报告
- 方式：只审不改；逐条读文档原文 + `grep` 对照代码现状（不改任何文件，未提交、未推代码）
- **结论：共 16 项：P1 3 项，P2 13 项。** 其中 3 项 P1 是 Batch 5 代码改动后文档未跟上（或被同批另一改动推翻）造成的新过期；其余为 B5 报告自身计数/表述出入与 Batch 5 后新增内容的文档缺位。
- P1 定义（沿用 SELF-REVIEW）：与既定决定或代码现状直接冲突，按文档行事会改错代码或误导用户；P2：文档过期、计数/表述不准、缺位、误导裁决。

---

## P1（3 项）

### SR2-DOCS-1 边界 §4.2 与 D-15 的“超限只提示不硬性拦截”已被 Batch 5 的 SR-P1-14 代码改动推翻

- 位置：
  - `docs/quiz-master2-mo-kuai-bian-jie-hua-fen.md:85`（§4.2）：“PDF 上限 50MB、图片上限 20MB，超限只提示不硬性拦截”
  - `docs/decision-log.md:133`（D-15）：“只收 PDF/JPG/PNG（PDF 50MB / 图片 20MB，超限只提示不硬拦）”
- 现象：Batch 5 按已定修法 (a) 把图片 20MB 也改成了硬判，上述两处文档仍写旧口径。按文档行事会认为超限文件仍可导入，与现状相反。
- 证据：
  - 代码：`lib/services/import_service.dart:213-225`——“单文件大小上限（§6 第 3 条）：PDF 50MB / 图片 20MB，复制前 [硬判]”“SR-P1-14：图片与 PDF 同款硬判，不再只提示不执行”，超限进 `failed` 任务；`lib/modules/collect/collect_page.dart:841-843` 超限横幅已同步改写为“文件超过大小上限，导入会失败。”“超限的文件会记为失败任务，其他文件正常导入。”
  - B5-P1-DATA 只改了代码与横幅，未改这两处文档；SR-P1-14 本身不是文档项，故无报告认领。
- 修的方向：两处都改为“PDF 50MB / 图片 20MB，超限硬判进失败任务（可先压缩再重选）”；并核对 `oversizeHint` 的“提示”定位（选文件时的事前提示仍在，`import_service.dart:148-152`）。

### SR2-DOCS-2 decision-log D-04 补注“`demoQuestions()` 仅作定义保留”已被同批 SR-P2-13 的删除推翻

- 位置：`docs/decision-log.md:35-37`（D-04 末尾补注，Batch 5 第四阶段 SR-P1-34 所加）：“`demoQuestions()` 仅作定义保留，目前没有任何生产调用方，上面 9 道题是演示库 v1（老库）的口径”
- 现象：第五阶段 SR-P2-13 已把 `demoQuestions()` 整个函数删除，D-04 补注指向一个不存在的函数；按注记去找定义会找不到。
- 证据：
  - 代码：`lib/data/demo_data.dart:3-8` 注释“SR-P2-13：`demoQuestions()` 已删除——新库从空开始、不预置演示题……留着是误导”；全仓 `grep demoQuestions lib/` 除该注释外 0 命中（定义已无）；`test/b5_p2_data_test.dart:5` 同样写明“SR-P2-13 是删除无调用方的 `demoQuestions()`”。
  - 时序：第四阶段先写了“仅作定义保留”，第五阶段删了函数，两阶段报告均未回头修正 D-04。
- 修的方向：D-04 补注改为“`demoQuestions()` 已于 Batch 5（SR-P2-13）删除；演示题的唯一合法来源是 v1 老库（已整体删除，不迁移）”；`demoExams()` / `demoKnowledgePoints()` 仍在 `_seed` 里用，保留的说法不变。

### SR2-DOCS-3 decision-log D-23 正文仍写“回退占位”与“落盘/渲染仍是待办”，与现行代码相反

- 位置：`docs/decision-log.md:225-226`（D-23）：“模型缺失、加载失败或图片文件不存在时回退占位（一页一个整题框），不抛错”；`:251-253`：“`detectPage` 按传入路径找文件，找得到跑真实推理，找不到回占位。真实文件落盘 / PDF 渲染仍是待办，见 YOLO 报告。”
- 现象：D-23 是现行 YOLO 接入的 operative 决定（D-07 已标注被它取代），其正文两处关键句仍是 2026-11-13 的旧口径。SR-P2-71 只修了 `YOLO-INTEGRATION-REPORT.md`，未修 D-23 本体。
- 证据：
  - 代码：`lib/services/yolo_onnx_service.dart`（B5-P2-DOCS 已核对 `:11-16,44-45,130-131,144-173`）——失败返回空框 + `usedFallback: true`，不回占位框；`lib/services/import_service.dart:14,20,43-64` 导入已真实落盘到 `imports/<task-id>/`；`lib/services/pdf_render_service.dart` 已按页渲染（`pages/`）。
  - 对照：`docs/ui-replication/YOLO-INTEGRATION-REPORT.md` §2/§4/§8 已按同一口径改完，同一事实在两份文档里说法相反。
- 修的方向：D-23 两处改为与 YOLO 报告一致——“模型缺失/加载失败/文件不存在时返回空框 + `usedFallback: true`，不回占位框”；“导入已真实落盘（`imports/<task-id>/`），PDF 由 `pdf_render_service.dart` 按页渲染”；若 D-23 正文其余历史句（如“版本故意不 pin 到此为止”）仍有效，只改这两句。

---

## P2（13 项）

### SR2-DOCS-4 边界 §4.2“已整理完成的任务仍留在列表中”：`done` 状态在现行流程中到不了，读者看到的已整理任务显示为“待整理”

- 位置：`docs/quiz-master2-mo-kuai-bian-jie-hua-fen.md` §4.2（Batch 5 第四阶段 SR-P1-24 所改）：“已整理完成的任务仍留在列表中（可删除），不自动归档、不隐藏”
- 现象：该句按字面理解为“整理完的任务以‘已整理’状态留在列表”。实际上没有任何生产代码会把任务置为 `done`；整理完成后任务仍是 `pendingOrganize`，行上显示“待整理”。文档的状态标签与界面实际标签对不上。
- 证据：
  - 代码：`lib/modules/collect/collect_page.dart:135-139` 注释“SR-P2-33：`CollectStatus.done` 全仓无赋值处——没有任何生产代码会把任务置为 `done`（已整理任务仍以 `pendingOrganize` 呈现）；这里的 `done` 分支是防御性保留”；`grep CollectStatus.done lib/` 只有解析（`db_codec.dart:181` 读回旧库字符串）与防御分支（`collect_page.dart:1284,1315,1390`），无赋值。
  - 反向核实：`_tasks = tasks` 不过滤（`:177`），`done` 行若从旧库读回确实会显示并可删除——所以该句对“旧库残留行”成立，对现行流程产生的任务不成立。
- 修的方向：改为“修框确认后（待整理状态）的任务一直留在列表中（含已整理进错题本的题对应的任务，行上仍显示‘待整理’，可删除）；`done` 状态仅作旧库防御保留，现行流程不产生”。原正确表述（SR-P1-24 修前）是“已整理完成的任务归档，不再出现在列表中”，该句本身是错的，不要恢复。

### SR2-DOCS-5 README 与代码地图的 `demoQuestions()` 行仍写函数存在（与 SR2-DOCS-2 同根）

- 位置：
  - `README.md:61`：“演示数据定义：数学/英语/政治各 3 道大学题（`demoQuestions()`，共 9 道）+ 演示试卷/知识点树”
  - `docs/代码地图.md:118`（§2 `demo_data.dart` 行）：“演示数据定义：数学/英语/政治各 3 道大学题（共 9 道，`demoQuestions()`）+ 演示试卷/知识点树。注意：新库建库时**不**预置演示题（§6 第 1 条），`demoQuestions()` 目前没有生产调用方”
- 现象：与 SR2-DOCS-2 同一事实——函数已删（`lib/data/demo_data.dart:3-8`），两处仍写它存在且有 9 道题。
- 修的方向：两处改为“演示题定义已删除（Batch 5 SR-P2-13）；`demo_data.dart` 只剩演示试卷/知识点树定义（`demoExams()` / `demoKnowledgePoints()`，供 `_seed` 用）”。

### SR2-DOCS-6 边界 §4.4 同一节内“不设序号”与“左上角蓝色序号圆盘”直接矛盾，口径未定

- 位置：`docs/quiz-master2-mo-kuai-bian-jie-hua-fen.md:136`（§4.4 大卡片）：“卡片上只有整题切片图与左上角蓝色序号圆盘”；`:144`（§4.4“不管什么”）：“不显示试卷来源、不显示复习次数、不显示收集时间、不设序号”
- 现象：同一节既肯定大卡片有序号圆盘，又在“不管什么”里说“不设序号”。B5-DOCS-BOUNDARY 遗留 10 与 B5-DOCS 遗留、B5-P2-DOCS 遗留 2、B5-P2.md 遗留均只记为“观察，未改”。
- 证据：
  - 代码：`lib/modules/wrongbook/wrongbook_list.dart:706` 注释“序号 = 本页内的位置（1, 2, 3…），随排序 / 筛选 / 分页重编号”；`:740-779` `_buildLargeCard` 确有左上角蓝色序号圆盘；紧凑列表行（`:815-828`）无序号。
  - 两种可能口径均未在文档里定：(a)“不设序号”指紧凑列表行不设行号，大卡片圆盘是页内位置号，不算“序号”；(b)“不设序号”是旧句残留，应删。
- 修的方向：**需 Meng 裁决**——定 (a) 还是 (b) 后统一两处表述；若定 (a)，在 :144 句后加括号注“（指紧凑列表行不设行号；大卡片左上角页内位置圆盘保留）”。

### SR2-DOCS-7 CODEBUDDY 与四方分工仍写“第五批修复进行中”，Batch 5 已全部完成

- 位置：
  - `docs/CODEBUDDY.md:44`：“最终自审已做完（见 `docs/ui-replication/SELF-REVIEW-SUMMARY.md`，第五批修复进行中）”
  - `docs/四方分工.md:8-9`（基线行）：“第五批修复进行中，通过数会随修复推进变化”；`:60`（眼前第一步）：“最终自审已做完，第五批修复进行中；Meng 在自审汇总后决定是否推送代码”
- 现象：Batch 5 五阶段已全部完成（B5-SUMMARY，测试 778/778），“进行中”已是过期状态描述；四方分工基线行的“最新数以 B5-SUMMARY 为准”注记本身真实存在且已生效（见“已核实干净”第 5 条），问题仅在“进行中”三字。
- 修的方向：三处“第五批修复进行中”改为“第五批修复已完成（2026-11-15，测试 778/778，未推代码；下一步第二次自审 → Meng 决定是否推送）”；基线行的 628/628 快照本身带日期与“以 B5-SUMMARY 为准”注记，可保留。

### SR2-DOCS-8 代码地图头注仍只写到 Batch 4，未提 Batch 5

- 位置：`docs/代码地图.md:6-15`（头注）：“本文 2026-11-14 按第三批修复（Batch 3）后的代码重写过关键小节……第四批 God 类拆分（Batch 4）后的文件结构见第 2、3、6 节。仓库里仍有 Batch 1/2/3/4 未提交的改动……最终验证已跑——B3 与 B4 均已由协调员跑过最终统一验证：`flutter analyze` 0 问题、全量测试 628/628 通过（Batch 4 结束时）”
- 现象：SR-P1-38 的修复（头注称“最终验证还没跑”）本身已落实，但头注的“最新验证”仍停在 Batch 4；Batch 5 的改动（P0–P2、测试 778/778）未在头注留位置，读者按头注会以为 628/628 是最新数。
- 修的方向：头注补一句“Batch 5（最终自审 134 项修复）已完成、未提交未推；最终验证：analyze 0 问题、全量测试 778/778、Linux Release 构建成功，结论见 `B5-SUMMARY.md`”；并把“仍有 Batch 1/2/3/4 未提交的改动”改为“Batch 1/2/3/4/5”。

### SR2-DOCS-9 代码地图里 Batch 5 新增的共享函数与新测试文件没有位置

- 位置：`docs/代码地图.md` §2 文件表（`lib/data/repository.dart` 行 :117 只写“各页面共用的业务查询口径（要复习的题、错因自查等）”）、§3 数据流、`test/` 说明（:152 只写“测试文件，每个模块基本都有一个 `*_test.dart`”）
- 现象：Batch 5 新增的跨页共享入口在代码地图里查不到：
  - `ReviewBucket` / `reviewBucketOf()` / `isReviewDue()`（`lib/data/repository.dart:18-43`；首页、错题本封面、今日待办三处共用的互斥拆分，SR-P1-1 的核心改动）；
  - `normalizeBoxEditorInputs()`（`lib/modules/collect/box_editor.dart:120`；SR-P1-5/6 的 Layer-2 归一化单函数）；
  - `normalizeWrongbookSort()` / `wrongbookSortValues`（`lib/models/models.dart:593-607`；SR-P0-2 的排序值归一）；
  - `_hasSplitSibling` 信号（`lib/modules/collect/collect_page.dart:125,132,181,1151`；SR-P2-25 的保留任务识别信号）；
  - 新测试文件 `test/b5_p0_1_orphan_test.dart`、`test/b5_p1_1_subject_counts_test.dart`、`test/b5_p1_256_test.dart`、`test/b5_p2_data_test.dart`、`test/b5_p2_collect_test.dart`、`test/b5_p2_services_test.dart`、`test/import_service_p1_fixes_test.dart`（`test/` 目录实测已存在，代码地图只字未提）。
- 修的方向：在 §2 `repository.dart` 行补 `ReviewBucket` 三件套一句话；在 §4 收集中心/错题本小节或 §2 `box_editor.dart` / `models.dart` 行补归一化函数与排序归一各一句话；`test/` 说明补 B5 回归测试文件清单（或注明“Batch 5 回归测试见 `test/b5_*.dart`”）。

### SR2-DOCS-10 B5-DOCS.md 与 B5-SUMMARY.md 的第四阶段范围串漏了 SR-P1-25、SR-P1-26

- 位置：
  - `docs/ui-replication/B5-DOCS.md:4`：“范围：最终自审文档 P1 22 项（SR-P1-18～SR-P1-24、SR-P1-27～SR-P1-39）”
  - `docs/ui-replication/B5-SUMMARY.md:15`（阶段表第四行）：“SR-P1-18～24、P1-27～32、P1-33～39”
- 现象：两处范围串的并集是 18–24（7 项）+ 27–39（13 项）= 20 项，漏了 SR-P1-25、SR-P1-26，却都称 22 项。工作本身没有漏修——`B5-DOCS-BOUNDARY.md` 范围行明确含“SR-P1-25、SR-P1-26”，正文亦有 §4.4 两条改动；错的是汇总层面的范围串。
- 修的方向：两处范围串补上“SR-P1-25、SR-P1-26”（或直接写“SR-P1-18～SR-P1-39”）。

### SR2-DOCS-11 B5-P1-COUNTS.md 标题“6 项”与正文 7 项不符

- 位置：`docs/ui-replication/B5-P1-COUNTS.md:4`：“范围：最终自审 P1 口径类 6 项（SR-P1-1、SR-P1-9、SR-P1-10、SR-P1-11、SR-P1-12、SR-P1-13、SR-P1-15）”
- 现象：括号里列了 7 个编号（P1-1、9、10、11、12、13、15），标题却写 6 项；正文亦按 7 项分节（SR-P1-1、SR-P1-10+11、SR-P1-9+13+12、SR-P1-15），测试算术 661 + 13 = 674（4+2+5+2）与 7 项一致。
- 修的方向：标题“6 项”改为“7 项”。

### SR2-DOCS-12 B5-P2-COLLECT.md 与 B5-P2.md 的收集组计数错误，SR-P2-22 被两组重复计入

- 位置：
  - `docs/ui-replication/B5-P2-COLLECT.md:5-6`：“原任务 18 项（SR-P2-18、19、20、21、23、24、25、26、27、28、29、30、31、32、33、34、35；SR-P2-22 不属原任务）+ 补充转交 4 项……结论：22 项全部完成”
  - `docs/ui-replication/B5-P2.md:26`：“收集/整理/详情（原 18 项 + 转交 4 项，全部完成）”
- 现象：括号里列出的原任务编号实际只有 17 个（18、19、20、21 共 4 个；23、24、25 共 3 个；26–35 共 10 个），不是 18 项；17 + 4 = 21，不是 22。另 SR-P2-22 同时出现在数据层工人范围（B5-P2-DATA“P2-1～17、22（部分）”）与收集组转交（“SR-P2-22 剩余部分”）里，两组计数都含它，汇总时未说明是同一项分两半。
- 修的方向：原任务改为“17 项”，结论改为“21 项全部完成”（或把 P2-22 的拆分口径写清：数据层半项 + 收集组半项，合计仍算 1 项）；B5-P2.md 同步改。

### SR2-DOCS-13 B5-P2.md 称“删 `CollectStatus.done` 死分支”，与工人报告及代码都矛盾

- 位置：`docs/ui-replication/B5-P2.md:27`（收集组摘要）：“……`_donePages` 文案说清；切页/取消保存加 try；`firstWhere` 兜底；删 `CollectStatus.done` 死分支与 `DashedDivider`/`InfoChip` 死代码……”
- 现象：`done` 分支没有被删。工人报告原文是保留（`B5-P2-COLLECT.md` SR-P2-33 行：“`done` 分支保留作防御，并在 `_load` 的 `splitPagesBySource` 处加了说明注释。无行为可测”）；代码里 `done` 分支仍在（`lib/modules/collect/collect_page.dart:1284` 行文案、`:1315` 状态 pill、`:1390` 删除按钮，另 `:135-139` 防御注释）。
- 修的方向：B5-P2.md 该句改为“`CollectStatus.done` 分支保留作防御（旧库读回时仍显示；现行流程不产生 `done`，见 SR-P2-33）；删 `DashedDivider`/`InfoChip` 死代码”。

### SR2-DOCS-14 B5-SUMMARY 与 B5-P2 的遗留“报告页月筛选口径仍为 `age <= 30`”指错了页面

- 位置：
  - `docs/ui-replication/B5-SUMMARY.md:52`（遗留·需 Meng 裁决）：“报告页月筛选口径仍为 `age <= 30`（自审未定）”
  - `docs/ui-replication/B5-P2.md:63`（遗留）：“需 Meng 裁决：报告页月筛选口径仍为 `age <= 30`（自审未定，错题本工人未动）”
- 现象：`age <= 30` 的月口径不在报告页，在错题本列表的时间筛选；报告页的“本月”是自然月（当月 1 日起），两处口径本就不同，遗留把待裁决项安到了错误的页面，会误导 Meng 去裁决一个不存在的问题。
- 证据：
  - 代码：错题本 `lib/modules/wrongbook/wrongbook_page.dart:574-584`——`limit = week ? 7 : 30`，月分支 `age <= limit`（即 31 天含今天），筛选项“最近一月”（`wrongbook_list.dart:278`）；报告页 `lib/modules/report/report_page.dart:111-113`——`'month' => DateTime(now.year, now.month, 1)`，全文无 `age`、无 `30`（`grep age|30|difference lib/modules/report/report_page.dart` 仅命中无关行）。
  - 正确出处：`B5-P2-WRONGBOOK.md:20` SR-P2-45 行写的是“月筛选 `age <= 30` 未动”，上下文是错题本组，本身没错；错的是汇总到 B5-SUMMARY/B5-P2 时前面加了“报告页”。
- 修的方向：两处遗留改为“错题本列表‘最近一月’筛选口径仍为 `age <= 30`（31 天含今天，自审未定；报告页‘本月’是自然月 1 日起，两处口径本来就不同，是否统一需另定）”。

### SR2-DOCS-15 SELF-REVIEW.md SR-P2-81 的证据句“`reviewCount` 仍保留显示”失实

- 位置：`docs/ui-replication/SELF-REVIEW.md:663`（SR-P2-81）：“……复习次数（`reviewCount`）仍保留显示。证据：`lib/modules/detail/question_detail_page.dart:17`；`:1587-1611`（每错因‘下次复查 …’）”
- 现象：`reviewCount` 只存模型与库，从未在任何页面渲染；所引的两处证据只能证明“每错因下次复查日”存在，证明不了题级复习次数有显示。B5-P2-DOCS 已正确偏离自审字面方向（只写每错因解决次数与下次复查日，未写“复习次数”，见其遗留问题 1），处理正确；失实的是 SELF-REVIEW 原文。
- 证据：`grep -rn "\.reviewCount\|reviewCount:" lib/`——仅 `lib/models/models.dart:288,326,357,394`（模型字段）、`lib/data/db_codec.dart:72,105`（写回/读回）、`lib/modules/detail/question_detail_page.dart:268`（`_saveEdit` 时原值透传 `reviewCount: base.reviewCount`，不渲染）；`grep -rn "reviewCount" lib/modules/` 除上述透传外无任何展示用引用；边界 §4.6 现写“复习记录（各错因状态、解决次数、下次复查日与全部解决记录）”与代码一致，无“复习次数”。
- 修的方向：SELF-REVIEW.md 是已冻结的审阅记录，不宜改写正文；在本报告与 B5-P2-DOCS 遗留 1 处留档即可，并提醒 GPT 一次性复审不要以该句为准。题级复习次数是否应显示，仍是 B5-SUMMARY 遗留的另立产品改动（`reviewCount` 只存不用）。

### SR2-DOCS-16 B5-P2.md 的测试净增数 104 与各组新增数之和 108 对不上，差额未具名

- 位置：`docs/ui-replication/B5-P2.md:56`（阶段统一验证）：“全量测试：**778/778 通过**（基线 674，净增 104；新测试文件 `b5_p2_data_test` 36、`b5_p2_collect_test` 27、`b5_p2_services_test` 14，另有错题本/复习/首页/学科管理/设置各文件新增；个别旧测试随行为变更删除/合并，计数口径以全量为准）”；同文件 :30：“新增回归测试 31 项”（错题本组）
- 现象：36 + 27 + 14 + 31 = 108，与净增 104 差 4。报告只用“个别旧测试随行为变更删除/合并”一笔带过，未写明删/并的是哪 4 项（或哪几处），从报告本身无法复算。
- 修的方向：在该句后补被删/合并的测试清单（如“删除 X 测试 2 项、合并 Y 测试 2 项，见 B5-P2-WRONGBOOK.md §x”）；若实为 31 项中有 4 项是改写既有测试而非新增，改为“新增 27 项 + 改写 4 项”。

---

## 已核实干净（逐项一句话）

1. **SR-P1-18**：边界 §4.3 表单已按五段现状重写（修框切片/文件夹（归类）/来源/分类补充/答案·解析·笔记，无学科字段，只有文件夹必填，“备注”→“笔记”），与 `organize_page.dart:826,1132,1140,1149,1158` 的分段标题逐字一致。
2. **SR-P1-19**：边界 §4.3 已改为左图右表整页滚动、队列为左上角按钮后弹出层，与 `organize_page.dart:597,669,686` 的 `SingleChildScrollView` 与 `:404-406` 的 `OverlayEntry` 一致。
3. **SR-P1-20**：边界 §4.3 待补充已改为只统计文件夹（唯一必填项），与 `organize_page.dart:1171-1176,2202` 一致。
4. **SR-P1-21**：边界 §4.2 两处已改为默认“请选择学科”、每次必选、不预选，`CollectPage` 构造器（`collect_page.dart:41-47`）无预选学科参数，hint 即“请选择学科”（`:1012`）。
5. **SR-P1-22**：边界 §4.2 已改为取消导入/取消排队直接删任务、不弹确认、不停留修框中，与 `collect_page.dart:736-744` 的 `_removeTask` 一致；失败任务删除走模态确认（`:746` 起 `_deleteTask`）亦已写明。
6. **SR-P1-23**：边界 §4.2 已补 P1-2 例外（有未框页时原任务按同 id 重建保留），与 `collect_page.dart:630-675` 的 `retained` 构造与 `confirmSplit` 同事务提交一致。
7. **SR-P1-24（行为核实）**：`done` 任务行确实不过滤（`collect_page.dart:177` `_tasks = tasks`，`:1390-1395` `done` 行有删除按钮），B5 的“仍留在列表中”在“旧库读回行”层面成立；仅状态标签口径问题见 SR2-DOCS-4。
8. **SR-P1-25**：边界 §4.4 筛选已删“文件夹”、补“知识点、错因”，并注明文件夹在目录页选；`wrongbook_list.dart:289` 下拉名为“错因状态”，`:348,361` 有知识点与错因 chip。
9. **SR-P1-26**：边界 §4.4 大卡片已改为只有切片图 + 左上角蓝色序号圆盘、无文字信息，与 `wrongbook_list.dart:726` 起 `_buildLargeCard` 及 `:720-724` 注释逐字一致。
10. **SR-P1-27**：边界 §5.1 已按 D-13 移入新 §4.6，§3 表已改“已确认”；详情页三段默认全折起（`question_detail_page.dart:9,109` `_expanded` 初始为空）。
11. **SR-P1-28**：边界 §5.2 已按 D-14 移入新 §4.7，“按试卷分布”明确写已否决；报告页 Top5 按题 id 计数、排除未整理/已归档（`report_page.dart:177-180`）。
12. **SR-P1-29**：边界 §5.1 已改为标签与试卷在此维护、文件夹只在目录页、自定义错因无全局定义，与 `subjects_page.dart` 四段（学科/知识点树/标签/试卷）一致。
13. **SR-P1-30**：边界 §5.1 待确认点已只剩知识点树编辑粒度与文件夹/标签合并重命名规则，学科删除已实现与设置五组已定均已写入。
14. **SR-P1-31**：边界 §2 数据层已改为“错因解决记录与复查日、自查历史、复习会话断点”，旧字段 `review_status`/`next_review` 全仓仅剩 `database.dart:95` 的删除注释。
15. **SR-P1-32**：边界 §4.1 已改为“继续上次”按最近任务 kind 分流去整理/收集/复习，与 `home_page.dart:200` 起 `_resumeRecent` 一致。
16. **SR-P1-33**：D-07 标题与首行已标注“已被 D-23 取代，仅留作历史”；D-23 正文残留见 SR2-DOCS-3。
17. **SR-P1-35**：D-06 优先级规则删除已写入 D-06 与 D-01，边界 §4.1 同步为“最后一次活动优先”，代码 `saveRecentTask` 未动（只改文字）与注记一致。
18. **SR-P1-36/四方分工基线（任务 3 前半）**：基线行确为 628/628 快照，且“最新数以第五批汇总 `B5-SUMMARY.md` 为准”的注记真实存在（`四方分工.md:8-10`），B5-SUMMARY 已生成且写明当前 778/778，注记不误导；仅“进行中”三字过期，见 SR2-DOCS-7。
19. **SR-P1-37**：CODEBUDDY 已补 Batch 4 拆分节（`database.dart` 3191→541 + 10 个 part、`collect_page.dart` 3349→1316 + `box_editor.dart`、`wrongbook_page.dart` 3718→1141 + 5 个 part），均标注“Batch 4 结束时”快照，行数与当时实测一致。
20. **SR-P1-38/39**：代码地图头注“最终验证还没跑”已改；§2 文件表已按 B4 结构重写（入口 + part 清单）、§3/§6 的 `createTables` 已指向 `db_schema.dart createTablesImpl`；全文残留的 `database.dart` 引用逐条核对均正确（入口本身、`AppDatabase` 类、同签名转发、测试钩子、`backupTables` 确在 `database.dart:113`）。
21. **SR-P2-78**：边界 §4.2 已改为“框重叠时确认按钮禁用并行内警告”，与 `box_editor.dart:1050` 的 `confirmEnabled` 与 `:1157-1160` 横幅文案一致。
22. **SR-P2-79**：边界 §4.4 已改为固定 466px 容器约 2.5 张卡（第三张露一半），与 `wrongbook_list.dart:687-700` 与 `design_tokens.dart:646` 一致。
23. **SR-P2-80**：边界 §4.4 筛选已改为“错因状态”，与 `wrongbook_list.dart:289` 一致。
24. **SR-P2-81（边界本身）**：新 §4.6 已补“下次复查日”，写的是每错因解决次数与下次复查日，未写不存在的题级“复习次数”，与详情页 `:1644,1672` 一致；自审原文失实见 SR2-DOCS-15。
25. **SR-P2-82/83**：边界已改为“共 8 个模块、9 个页面、9 条路由；已确认 7 个页面（7 行、7 个模块）；未确认 2 个页面、2 条路由、1 个模块”，与 `app.dart:30-38`（8 条顶级路由）+ `/question/:id` 共 9 条一致。
26. **SR-P2-84**：边界 §5.1 字号已补“特大”，与 `models.dart:540,676-677` 三档一致。
27. **SR-P2-85**：边界 §1 已加“模块按业务归属计”注，§5.1 已补交叉引用，计数 8 模块未变，与已定决定 (a) 一致。
28. **SR-P2-86**：README 两处“第 2 层已移除”已改为“第 2 层暂缓”；`B2-LEFTOVER-DOCS.md` 里的“已移除”是已冻结的历史报告原文，不在本次修复范围。
29. **SR-P2-87**：README 结构树已列 B4 新增文件（`db_*.dart` 10 个、`box_editor.dart` + `collect_widgets.dart`、wrongbook 5 个 part），与 `ls lib/data/db_*.dart`、`lib/modules/collect/`、`lib/modules/wrongbook/` 一致。
30. **SR-P2-88**：D-06 已加注“三数指错题本封面徽章口径（`subjectCounts`）；首页学科格为要复习/待整理两数”，与 `repository.dart:148-175` 与 `home_page.dart:649` 一致。
31. **SR-P2-89**：四方分工“眼前第一步”已改写为最终自审→决定推送的当前阶段，并注初版写于 2026-11-14 18:26；仅“进行中”过期，见 SR2-DOCS-7。
32. **SR-P2-90**：代码地图 §5 示例注释已改为 `// lib/data/db_codec.dart，_toRow`（`:811`），全文无 `L148`/`L2152` 类旧行号引用。
33. **B5 覆盖完整性**：脚本核对 SELF-REVIEW.md 全部 134 个编号在 B5 系列报告中都有出现，且 B5 报告中无 SELF-REVIEW 之外的编号——无多修/错修、无漏修（编号层面）。
34. **B5 测试数 progression 一致**：628 → 635（B5-P0：628+7）→ 661（B5-P1-DATA：635+26，分项 3+1+1+3+8+10=26）→ 674（B5-P1-COUNTS：661+13，分项 4+2+5+2=13）→ 674（B5-DOCS，无新增）→ 778（B5-P2：674+104），各阶段报告与 B5-SUMMARY 阶段表一致。
35. **SR-P2-56 / SR-P2-77 交代清楚**：56 不修见 B5-SUMMARY、B5-P2.md、B5-P2-WRONGBOOK.md（“56 跳过，已裁决残留”）；77 只动测试侧见 B5-SUMMARY、B5-P2.md、B5-P2-SERVICES.md（13 个 PDF 测试 + 4 个 YOLO 冒烟测试各加 5 分钟超时，无产品代码改动）。
36. **YOLO 报告测试数 674**：`YOLO-INTEGRATION-REPORT.md:6,139` 的 674/674 明确标注“Batch 5 第四阶段结束时”，是带日期的快照，不误导；最终数以 B5-SUMMARY 的 778/778 为准。
37. **B5-SUMMARY 遗留另两项**：SR-P2-81 `reviewCount` 只存不用（需另立产品改动）与三项协调员裁决（P2-66、P2-51、P2-52/55）在 B5-SUMMARY、B5-P2.md、B5-P2-DOCS/B5-P2-WRONGBOOK 间表述一致。

## 需 Meng 裁决的新项（本报告新增）

1. **SR2-DOCS-6**：边界 §4.4“不设序号”与大卡片序号圆盘是否矛盾——定口径 (a) 紧凑列表行不设行号、圆盘保留，或 (b) 删“不设序号”旧句。
2. **SR2-DOCS-14 的反向问题**：错题本“最近一月”`age <= 30`（31 天含今天）与报告页“本月”自然月（1 日起）是否统一口径——B5 遗留把该问题错安在报告页，正确位置是错题本。
