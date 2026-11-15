# 第六批 P2 文档批量修复报告（B6-P2-DOCS）

- 执行员：F-docs（P2 文档批量）
- 时间：2026-11-15
- 范围：SELF-REVIEW-2 文档项 SR2-39、SR2-40、SR2-41、SR2-42、SR2-43、SR2-44、SR2-45、SR2-46、SR2-47、SR2-48、SR2-50（SR2-49 只留档，不改文件）
- 分支：`ui-replication`；工作树 `~/workspace/quiz-master2-UI`
- 性质：**纯文档改动，未动任何代码**；未提交、未推代码；未动 git 历史

## 逐项结果

### SR2-39 — 边界 §4.2 done 状态口径

- 文件：`docs/quiz-master2-mo-kuai-bian-jie-hua-fen.md:88`
- 改：旧句“已整理完成的任务仍留在列表中（可删除），不自动归档、不隐藏”改为“修框确认后（待整理状态）的任务一直留在列表中（含已整理进错题本的题对应的任务，行上仍显示“待整理”，可删除），不自动归档、不隐藏；`done` 状态仅作旧库防御保留，现行流程不产生”。
- 核对：代码 `lib/modules/collect/collect_page.dart:135-139` 注释（`CollectStatus.done` 全仓无赋值处）与自审证据一致；未恢复修前错句“已整理完成的任务归档，不再出现在列表中”（grep 0 命中）。

### SR2-40 — 边界 §4.4“不设序号”口径（Meng 已定 (a)）

- 文件：`docs/quiz-master2-mo-kuai-bian-jie-hua-fen.md:144`
- 改：在“不设序号”后加括号注“（指紧凑列表行不设行号；大卡片左上角页内位置圆盘保留）”。
- 核对：代码 `lib/modules/wrongbook/wrongbook_list.dart:740-779` 大卡片确有左上角蓝色序号圆盘，`:815-828` 紧凑列表行无序号；与 Meng 定 (a) 一致。

### SR2-41 — “第五批修复进行中”改为已完成已推送

- 文件：`docs/CODEBUDDY.md:44`、`docs/四方分工.md:8`、`:60`
- 改：三处“第五批修复进行中”均改为“第五批修复已完成并已推送（2026-11-15 09:35，head 6448c45）；第六批修复进行中”。未照抄自审原文的“未推代码”（已过时）。
- 核对：三处 grep “第五批修复进行中” 0 命中。

### SR2-42 — 代码地图头注补 Batch 5

- 文件：`docs/代码地图.md:9-11`
- 改：头注补一句“Batch 5（最终自审 134 项修复）已完成、已推送（head 6448c45）；最终验证：analyze 0 问题、全量测试 778/778、Linux Release 构建成功，结论见 `B5-SUMMARY.md`”；“仍有 Batch 1/2/3/4 未提交的改动”改为“Batch 1/2/3/4/5”；另补一句“第六批修复进行中，其改动未提交”。
- 核对：头注内“Batch 1/2/3/4 未提交”0 命中；B5-SUMMARY.md 的验证数（analyze 0、778/778、Linux Release 成功）与头注新句一致。

### SR2-43 — 代码地图补 Batch 5 新增入口与回归测试清单

- 文件：`docs/代码地图.md:101`（`models.dart` 行）、`:118`（`repository.dart` 行）、`:135`（收集中心行）、`:153`（`test/` 说明）、`:498`（§4 收集中心）
- 改：
  - `repository.dart` 行补 `ReviewBucket`（pending / recheck / solved / none）与 `reviewBucketOf()` / `isReviewDue()`（`repository.dart:18-43`），注明首页、错题本封面、今日待办三处共用的互斥拆分（SR-P1-1）。
  - `models.dart` 行补 `normalizeWrongbookSort()` / `wrongbookSortValues`（`models.dart:593-607`），注明错题本排序值归一（SR-P0-2）。
  - 收集中心行补 `normalizeBoxEditorInputs()`（`box_editor.dart:120`），注明 Layer-2 框归一化单函数（SR-P1-5/6）。
  - §4 收集中心补 `_hasSplitSibling` 信号（`collect_page.dart:125,181,1202`），注明有同源拆分任务的 needBox 任务视为打开过修框、行上照样显示无框红色警告（SR-P2-25）。
  - `test/` 说明补 B5 回归测试文件清单：`test/b5_p0_1_orphan_test.dart`、`test/b5_p1_1_subject_counts_test.dart`、`test/b5_p1_256_test.dart`、`test/b5_p2_data_test.dart`、`test/b5_p2_collect_test.dart`、`test/b5_p2_services_test.dart`、`test/import_service_p1_fixes_test.dart`。
- 核对（实测行号，与自审引用的行号有轻微漂移，以实测为准）：
  - `ReviewBucket` 定义在 `repository.dart:18`，`reviewBucketOf()` 在 `:30`，`isReviewDue()` 在 `:41`，均在 18–43 范围内。
  - `normalizeBoxEditorInputs` 定义在 `box_editor.dart:120`。
  - `wrongbookSortValues` 在 `models.dart:593`，`normalizeWrongbookSort` 在 `:605`，均在 593–607 范围内。
  - `_hasSplitSibling` 字段在 `collect_page.dart:125`、赋值在 `:181`、使用在 `:1202`（自审引用的 `:1151` 已漂移，实测为准）。
  - 7 个测试文件均在 `test/` 目录实测存在。

### SR2-44 — 第四阶段范围串补 SR-P1-25、SR-P1-26

- 文件：`docs/ui-replication/B5-DOCS.md:4`、`docs/ui-replication/B5-SUMMARY.md:15`
- 改：B5-DOCS.md 范围串改为“SR-P1-18～SR-P1-39”；B5-SUMMARY.md 阶段表第四行改为“SR-P1-18～39”。
- 核对：两处旧范围串 grep 0 命中；22 项总数不变（18～39 共 22 项，含 P1-25、P1-26）；`B5-DOCS-BOUNDARY.md` 范围行原本就含 P1-25、P1-26，工作本身无漏修。

### SR2-45 — B5-P1-COUNTS 标题“6 项”→“7 项”

- 文件：`docs/ui-replication/B5-P1-COUNTS.md:4`
- 改：标题“最终自审 P1 口径类 6 项”改为“7 项”。
- 核对：括号内列出 7 个编号（P1-1、9、10、11、12、13、15），正文按 7 项分节，测试算术 661 + 13 = 674 与 7 项一致。

### SR2-46 — 收集组计数 18→17、22→21，P2-22 拆分口径写清

- 文件：`docs/ui-replication/B5-P2-COLLECT.md:5-6`、`:8`、`docs/ui-replication/B5-P2.md:26`
- 改：原任务“18 项”改为“17 项”（括号所列编号实为 17 个：18、19、20、21、23、24、25 共 7 个 + 26～35 共 10 个）；结论“22 项全部完成”改为“21 项全部完成”；§1 标题“原 18 项逐项结果”改为“原 17 项逐项结果”；两处均补拆分口径句“SR-P2-22 由数据层与收集组各做一半（数据层半项 + 收集组半项），合计仍算 1 项，不重复计入两组总数”。
- 核对：17 + 4（转交）= 21；B5-P2.md 分工表“P2-18～21、23～25、26～35 + 转交 4 项”本身未把 P2-22 计入原任务范围，无需改。

### SR2-47 — B5-P2.md 删 done 分支的错误说法

- 文件：`docs/ui-replication/B5-P2.md:27`
- 改：该句“删 `CollectStatus.done` 死分支与 `DashedDivider`/`InfoChip` 死代码”改为“`CollectStatus.done` 分支保留作防御（旧库读回时仍显示；现行流程不产生 `done`，见 SR-P2-33）；删 `DashedDivider`/`InfoChip` 死代码”。
- 核对：工人报告 B5-P2-COLLECT.md SR-P2-33 行原文即“`done` 分支保留作防御”；代码里 `done` 分支仍在（`collect_page.dart:1284` 行文案、`:1315` 状态 pill、`:1390` 删除按钮，另 `:135-139` 防御注释）。

### SR2-48 — 月筛选口径遗留指错页面（按 Meng 已定状态写）

- 文件：`docs/ui-replication/B5-SUMMARY.md:52`、`docs/ui-replication/B5-P2.md:63`
- 改：两处“报告页月筛选口径仍为 `age <= 30`（自审未定）”均改为已定状态：“错题本列表‘最近一月’筛选口径已定为 `age < 30`（30 天含今天，文案‘最近 30 天’；第六批修，SR2-48）；报告页‘本月’是自然月（当月 1 日起），两处口径本来就不同，不统一”，并括号注明原遗留指错了页面（见 SELF-REVIEW-2 SR2-48）。
- 核对：代码 `wrongbook_page.dart:574-584` 月分支确为 `age` 口径，`report_page.dart:111-113` 的“本月”确为自然月 1 日起、全文无 `age`/无 `30`；未照抄自审原文的“自审未定”。
- 注意：B5-SUMMARY.md:52 仍位于“**需 Meng 裁决：**”小节下，现为已定事项的记录——建议总协调在 B6-SUMMARY 中将其移出该小节（见“遗留问题”）。

### SR2-49 — 只留档，不改文件（SELF-REVIEW.md 已冻结）

- 未改 `docs/ui-replication/SELF-REVIEW.md`（`git diff` 该文件为空，已核实）。
- **警告（请总协调写进 B6-SUMMARY，并提醒 GPT 一次性复审）：不要采信 SELF-REVIEW.md SR-P2-81 的错误证据句“`reviewCount` 仍保留显示”。** 核实：`reviewCount` 只存模型与库，从未在任何页面渲染；所引两处证据（`question_detail_page.dart:17`、`:1587-1611` 每错因“下次复查 …”）只能证明每错因下次复查日存在，证明不了题级复习次数有显示。B5-P2-DOCS 已按代码事实处理（只写每错因解决次数与下次复查日，未写“复习次数”），处理正确；失实的是 SELF-REVIEW 原文。题级复习次数是否应显示，仍是 B5-SUMMARY 遗留的另立产品改动。

### SR2-50 — B5-P2.md 测试净增 104 的差额具名

- 文件：`docs/ui-replication/B5-P2.md:56`
- 改：在该句后补差额说明：“36 + 27 + 14 + 31 = 108 项新增，减去 SR-P2-34 随 `DashedDivider`/`InfoChip` 删除而删除的 `test/widgets_forward_test.dart` 4 项旧测试（`InfoChip 转发为 QmChip 展示态：不被当成 Disabled 置灰`、`InfoChip 带 color 时保留该色 10% 透明底`、`DashedDivider 纸线色转发为 QmRowLine paper 档`、`DashedDivider 其他色转发为 QmRowLine line 档`），净增 104；见 B5-P2-COLLECT.md SR-P2-34 行”。
- 核对（对照 B5-P2-WRONGBOOK.md 与实际测试文件）：
  - 错题本组 31 项构成：`wrongbook_page_test.dart` 新增 21 项 + `review_page_test.dart` 6 项 + `home_page_test.dart` 1 项 + `subjects_page_test.dart` 2 项 + `settings_page_test.dart` 1 项 = 31，与 B5-P2.md:30 的“新增回归测试 31 项”一致。
  - 4 项删除实测：`git diff -- test/widgets_forward_test.dart` 显示恰好删掉 4 个 `testWidgets`（2 个 InfoChip + 2 个 DashedDivider），与 B5-P2-COLLECT.md SR-P2-34 行“对应的 4 个测试已删（EmptyState 测试保留）”一致；`lib/` 内 DashedDivider/InfoChip 已零调用点。
  - 108 − 4 = 104，与净增数吻合。**不是**自审备选假设的“31 项中有 4 项是改写既有测试”——31 项全是新增，差额来自 4 项删除。
  - 另核实：B5-P2.md 协调员收尾所记“4 项旧测试同步”（SR-P2-66/P2-51 改行为后更新的旧测试）是改写、非删除，计数中性，不影响 104。

## 通用核对

- 旧说法 grep 核对：三处“第五批修复进行中”、边界旧句“已整理完成的任务仍留在列表中”与修前错句“已整理完成的任务归档”、"原 18 项"/"22 项全部完成"、"删 `CollectStatus.done` 死分支"、B5-DOCS/B5-SUMMARY 旧范围串、“口径类 6 项”、代码地图“Batch 1/2/3/4 未提交”——除两处有意引用的旧文案（SR2-48 新句括号内注明原遗留措辞；B5-DOCS.md:10 小节标题“SR-P1-18～SR-P1-24、SR-P1-27～SR-P1-32”本就是该小节的合法子范围）外，全部 0 命中。
- 未碰文件：`docs/ui-replication/SELF-REVIEW.md`（已冻结）、`docs/ui-replication/B5-P2-DATA.md`（C-data 执行员负责）——`git diff` 两文件均为空。
- 只改了任务书列出的 9 个文档；未动任何代码文件；未提交、未推代码。

## 遗留问题（请总协调定夺）

1. **SR2-48 位置**：B5-SUMMARY.md:52 的已定事项仍挂在“需 Meng 裁决：”小节下，建议 B6-SUMMARY 中将其移出或改写该小节。
2. **SR2-41 余留的过期句（超出本次指定改动范围，未动）**：`docs/CODEBUDDY.md:43`“Batch 1/2/3/4 的改动在工作树里，未提交、未推送”——Batch 5 已快照推送，本地仍未提交（快照推送不写本地历史，见四方分工约定），且第六批改动也在工作树里；`docs/四方分工.md:60-61`“Meng 在自审汇总后决定是否推送代码。推送前 Muse 按自审分批修”——推送已完成。建议下一批文档修复时顺手更新这两段。
3. **代码地图头注的 head 口径**：`docs/代码地图.md:10` 仍写“本地 head `bca8586`”，与已推 head 6448c45 的关系按快照推送约定（本地历史不写远端 head）是自洽的，未改；如需统一口径请协调员定。
4. **B5-P2.md:27 / B5-P2-COLLECT.md:6 仍称 `_hasSplitSibling` 为“持久化信号”**：与 SELF-REVIEW-2 SR2-22 的核实不符（每次 `_load` 由现存任务行派生，无落盘字段）。修法属 SR2-22 代码执行员，文档口径待其修后同步——本次 SR2-43 只在代码地图补了该信号的位置，未动这两处说法。
5. **代码地图 test 清单外的 B5 测试文件**：`test/b5_p1_3_delete_exam_test.dart` 在 `test/` 目录实测存在，但不在 SR2-43 指定的 7 文件清单内，本次未列入；请协调员确认它是否属 Batch 5（P1-DATA 阶段）并决定是否补入。
6. **SR2-49 警告**：见上文“SR2-49”节——GPT 一次性复审不要采信 SELF-REVIEW.md SR-P2-81 的“`reviewCount` 仍保留显示”一句。
