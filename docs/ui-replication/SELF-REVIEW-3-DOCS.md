# 第三次自审 · 文档 / 测试质量 / 口径核对报告（DOCS）

- 执行员：文档/测试质量/口径核对员（第三次自审）
- 日期：2026-11-15
- 分支：`ui-replication`；工作树 `~/workspace/quiz-master2-UI`
- 基线：Batch 5 已推 `6448c45`（778/778）→ Batch 6 已推 `38cbc4b`（852/852）
- 范围：只审第六批改动，不审全量代码；只读核对，未改任何代码、未提交、未推送。
- 方法：`git diff 6448c45..38cbc4b` 全量对照（含 lib/ 2054 行、docs/、test/）；逐文件 grep 计数复算；抽查 9 组新增/改动测试的断言原文；`flutter analyze` 全仓复跑一次；演示库 md5 实测。
- 结论：**P0 0 项、P1 0 项、P2 11 项**（DOCS-1～DOCS-11）。无 P0/P1。

## 逐条问题

### DOCS-1（P2）— B6-SUMMARY C-data 小节的测试数写错：`b5_p2_data_test` 应为 36→56，不是 36→55

- 位置：`docs/ui-replication/B6-SUMMARY.md` C-data 小节（"测试：`b5_p2_data_test` 36→55"）。
- 现象：总结写 36→55，但该文件最终是 56 项。
- 证据：`git grep` 计数：`6448c45` 时 36 项，`38cbc4b` 时 56 项；diff 为 +21/−1（C-data 新增 19 项 + SR2-59 改名 1 增 1 减 + GAPS 的 SR2-27 新增 1 项 = 36+19+1=56）。B6-SUMMARY 自己的 GAPS 小节也写了 SR2-27"测试 +1（`b5_p2_data_test.dart:721`）"，与 C-data 小节的 55 自相矛盾；若真是 55，全量总数应为 851 而非 852。
- 修的方向：总结 C-data 小节改为"36→56（C-data 新增 19 项 + SR2-27 补 1 项）"。注：`B6-P2-DATA.md` 自身写 36→55 在其成文时（02:09 UTC，GAPS 的 SR2-27 在 02:20 UTC 后才加）是对的，不用改；错的是事后汇总的 B6-SUMMARY。

### DOCS-2（P2）— 整理页测试基数写错："原 30 + 新增 9"应为 29+9

- 位置：`docs/ui-replication/B6-SUMMARY.md` A-queue 小节（"整理页测试 38/38（30 + 9 新增，含 1 个对照）"）；同款错误在 `docs/ui-replication/B6-P1-QUEUE.md`（"38/38 通过（原 30 + 新增 9"）。
- 现象：基数 30 是错的，38 的总数是对的。
- 证据：`git grep` 计数：`6448c45` 时 `test/organize_page_test.dart` 为 29 项；diff 为 +9/−0；29+9=38。30+9=39，与 38 对不上。
- 修的方向：两处均改为"原 29 + 新增 9 = 38"。

### DOCS-3（P2）— `docs/代码地图.md:10` 的 Batch 6 状态过期：仍写"第六批修复进行中"

- 位置：`docs/代码地图.md:9-11` 头注（"…第六批修复进行中，其改动未提交"）。
- 现象：与同批已更新的另外两处状态表述不一致。
- 证据：`docs/CODEBUDDY.md:44` 与 `docs/四方分工.md:60-61` 已由协调员同步为"第六批修复已完成、在工作树里，未提交、未推送"；代码地图头注仍写"进行中"。Batch 6 完成是总结全文的前提，该句已过期。
- 修的方向：头注同步为"第六批修复已完成（未提交、未推送，等 Meng 批准）"，或按 DOCS-11 的推送后状态一并更新。

### DOCS-4（P2）— B6-SUMMARY"遗留"漏收 7 处阶段报告级的遗留

- 位置：`docs/ui-replication/B6-SUMMARY.md` 末尾"遗留（未修 / 需另定）"小节。
- 现象：以下 7 条只在各阶段报告的"遗留问题"小节里，总结遗留未收录（总结的遗留不是全集，但这 7 条都是未解决的已知缺口，漏掉会让验收方以为已无遗留）：
  1. A-import：EXIF 镜像方向分支的"失败写库"未单独立用例（与"解不开图片"分支共用路径，未做触发器用例）——`B6-P1-IMPORT.md` 遗留第 2 条。
  2. A-detail：B5 的旧 P2-3 测试仍只覆盖"无旧切片"场景，有旧切片的覆盖在 `detail_page_test.dart`，两处未合并——`B6-P1-DETAIL.md` 遗留第 3 条。
  3. A-split：已拆过的页（`alreadySplit`）上后画的独立内框，确认时仍随 `continue` 静默丢弃——`B6-P1-SPLIT.md` 遗留第 1 条。
  4. A-queue：`_jumpToQuestion` 失败时弹出层已先关闭，用户需重开队列再跳——`B6-P1-QUEUE.md` 遗留第 2 条。
  5. D-services：SR2-38 的 `minSize: true` 分支里 `(minSize && …)` 判断恒为真（`!minSize` 已提前返回），留作原样——`B6-P2-SERVICES.md` 遗留第 2 条。
  6. D-services：SR2-31 的金角步进只在第 13 科钉死字面值，第 14、15…科未逐个断言——同文件遗留第 3 条。
  7. GAPS：SR2-73 的 500ms 等待是"等第二次检测到达 `_ensureLoaded`"的经验余量，解码极慢的环境下计数可能为 2——`B6-P2-GAPS.md` SR2-73 补跑重点。
- 修的方向：补进总结遗留（或在各阶段小节内保留并在遗留小节注明"另见各阶段报告"）。注：A-dropdown 的 `_filterExamId` / 复习页 `_subjectFilter` 未覆盖已在总结 A-dropdown 小节内写明，不重复。

### DOCS-5（P2）— B6-SUMMARY"遗留"中 SR2-16 一条已过时：影响面已由第三次全量确认

- 位置：`docs/ui-replication/B6-SUMMARY.md` 遗留（"SR2-16 对既有备份 fixture 的影响面待全量确认"）。
- 现象：该条仍列为待办，但第三次全量 852/852 已通过，其中含 `p1_schema_backup_test.dart`、`s8b4_backup_migration_test.dart` 等既有备份用例，影响面已确认无回归。
- 证据：总结"最终验证"小节自述第三次全量 852/852 通过、演示库 md5 不变；同一份总结的遗留仍写"待全量确认"，前后矛盾。
- 修的方向：该条移出遗留或标注"第三次全量已确认，无回归"。同条前半句"SR2-15 并发测试依赖 sqflite 事务串行化"是已知脆弱性而非待办，建议改述为"并发用例依赖串行化语义，换库后端时需复核"，不要与待办混列。

### DOCS-6（P2）— 工作树留有 4 个未入库的 TEMP 探针测试文件，本地再跑全量会计入 5 个额外用例

- 位置：工作树 `test/zz_probe_4way_test.dart`、`test/zz_probe_gate_test.dart`、`test/zz_probe_golden_test.dart`、`test/zz_probe_sr3_test.dart`（各 1/1/1/2 个用例，共 5 个）。
- 现象：4 个文件均未入库、不在已推提交 `38cbc4b` 内，头注均写"TEMP PROBE（delete after run）/ 临时探针（跑完删除）"，但仍留在树里；B6 各报告均未提及这批探针。
- 证据：`git ls-tree 38cbc4b -- test/` 无此 4 文件；mtime 为 2026-11-15 04:18–04:20 UTC，晚于 38cbc4b 推送（约 03:41 UTC），故不影响已推的 852/852 结论；但在当前脏工作树里再跑全量会是 857 个用例，且探针内容（4 路并发真实推理、gate 报错是否毒化 `_loadFuture`、金角 13–30 科复算）无报告记录结论。
- 修的方向：协调员确认各探针结论已记录后删除；引用 852 基线时注明以已推提交为准、不是脏工作树。**注意：其中 `zz_probe_sr3_test.dart` 是第三次自审兄弟执行员的在用探针，勿直接删；另有 `zz_probe_sr217_test.dart` 在核对期间已被其属主删掉，说明树内仍有并行探针活动，清理前须先确认。**

### DOCS-7（P2）— 任务清单 `/tmp/b6-files.txt` 漏了 README.md（B6 改动文件之一）

- 位置：`/tmp/b6-files.txt`（窗口 01:30–04:00 UTC，62 条）。
- 现象：清单无 README.md，但它是第六批改动文件。
- 证据：`README.md` mtime 2026-11-15 01:40:42 UTC，在窗口内；`git diff 6448c45..38cbc4b --name-only` 共 63 个文件，逐项比对后仅缺 README.md；其改动是 SR2-9（`demoQuestions()` 已删，见 `B6-P1-DOCS.md` 与 diff）。
- 修的方向：清单补一条 README.md。本项不是 B6 报告本身的问题，但按清单核对会漏审该文件，特此记录。

### DOCS-8（P2）— B6-P1-DOCS.md 的"已于 Batch 5（SR-P2-13）删除 3 处"验证口径小差

- 位置：`docs/ui-replication/B6-P1-DOCS.md`"全局核对"小节。
- 现象：报告称该说法 3 处，但按其所写的字面 grep 只能命中 2 处。
- 证据：`README.md:61-64` 的该句被换行断开（"…`demoQuestions()` 已于 Batch 5 / （SR-P2-13）删除…"），字面 grep 只命中 `docs/decision-log.md:36` 与 `docs/代码地图.md:119` 两处；措辞本身三处均已就位，错的是验证方法的宣称，不是改动。
- 修的方向：报告措辞改为"3 处（README 一处因换行断开，字面 grep 命中 2 处）"，或改用跨行核对。

### DOCS-9（P2）— 多处行号引用已漂移（不影响结论，仅备查）

- 位置：B6 各报告与 B6-SUMMARY 的行号引用。
- 现象：以下引用与当前文件行号不符（均为后续改动顶动行号所致，报告成文时部分已漂移）：
  - `B6-P1-DOCS.md`：代码地图 `:477`→实测 `:478`、`:118`→实测 `:119`。
  - `B6-P1-DETAIL.md`：B5 的 P2-3 回归测试组"约 :891-960"→实测 `test/b5_p2_collect_test.dart:1041`。
  - `B6-SUMMARY.md` A-detail："`replaceQuestionBoxesAndSlice` 实际在 `db_collect.dart:325`"→实测 `:338`。
  - `B6-SUMMARY.md` GAPS：`test/home_page_test.dart:110`→实测 `pumpHome` 在 `:111`。
- 修的方向：不逐条改旧报告；后续引用以 grep/符号为准。B6-SUMMARY 的 `:325` 一处建议随手改为 `:338`（它是总结正文，不是历史记录）。

### DOCS-10（P2）— SR2-56 测试的 hue 距离 helper 与产品 `_hueDistance` 同公式复写（有兜底，记为写法弱点）

- 位置：`test/subjects_page_test.dart:686` 起（本地 `hueDistance`）对照 `lib/modules/subjects/subjects_page.dart:63`（`_hueDistance`）。
- 现象：测试内复写了与实现相同的环形 hue 距离公式（差值 %360、>180 取补）；若产品公式算错，测试会同错——与 SR2-55 曾有的问题同类。
- 证据：同一用例先断言了字面值 `0xFFB34CD9`（`repo.subjectsList[12].color`），生成结果已被独立钉死；hue 循环只是第二道检查，风险已兜底。
- 修的方向：保留字面值断言为主；若日后重构，hue 循环改为只断言字面值，或改用与实现无关的 hue 计算，不再在测试内复写产品公式。

### DOCS-11（P2）— 推送后状态过期：CODEBUDDY.md / 四方分工.md / 代码地图.md 的"未推送"表述在 38cbc4b 推送后已失效（非第六批本身的错）

- 位置：`docs/CODEBUDDY.md:43-44`（"第六批修复已完成、在工作树里，未提交、未推送"）、`docs/四方分工.md:60-61`（"第六批修复已完成、在工作树里，未推送，推送等 Meng 另外批准"）、`docs/代码地图.md:10`（"本地 head `bca8586`"）。
- 现象：Batch 6 已于 2026-11-15 ~11:41 CST 经 Meng 批准推送，远端 head 现为 `38cbc4b`；上述三处仍写未推送/本地 head，与现状不符，"不要 push"的禁令对象也已不存在。
- 证据：`git log origin/ui-replication` 首条为 `38cbc4b Batch 6: fix second self-review 78 items…`；`git fetch` 后远端 head 即 38cbc4b。
- 修的方向：推送后同步更新三处状态（远端 head `38cbc4b`、Batch 6 已推），"不要 push"改为针对下一批。注：B6-SUMMARY 自身"不提交、不推送（推送须 Meng 另外批准）"是本批执行原则的历史记录，不用改。

## 已确认无问题

- **测试计数 778→852（净增 74）**：grep 计数 `771→845`，增量恰为 74；绝对数差已解释：2 处循环生成测试（`report_page_test.dart:586`、`review_page_test.dart:813` 的"亮/深 × 三档"组，各 1 个 occurrence 产 6 个用例，+10）减 3 处注释内 `test(` 误命中（`p05_image_pipeline_test.dart:87`、`p2_main_chain_test.dart:4`、`pdf_render_service_test.dart:3` 的 `//` 注释，−3）：771−3+10=778，845−3+10=852。逐文件增量与各阶段报告一致（import +8、256 +1、collect +2、organize +9、detail +1、data +20、orphan +1、services +11、wrongbook +11、review +2、report +1、subject_counts +1、yolo +2、b5_p2_collect +4，合计 74）。
- **SR2-50（108−4=104；错题本组 31=21+6+1+2+1）**：36/27/14 为三新文件在 `6448c45` 的实测总数；`B5-P2-WRONGBOOK.md` 行级求和：错题本文件 21（P2-36 组 5 + 其余 16，P2-39 的 1 项属复习页）、复习 6、首页 1、学科 2、设置 1，合计 31；`test/widgets_forward_test.dart` 在 B5 diff（`d7029a0..6448c45`）中恰好 −4（2 个 InfoChip + 2 个 DashedDivider）；"31 项中有 4 项是改写"的备选假设不成立，与报告结论一致。
- **两处纠正核实**：GAPS.md 的 SDK 误判——SDK 一直在 `~/workspace/flutter-install/flutter/bin/`，实测 `Flutter 3.47.9`，工人只查了 PATH；SR-P2-6"已测"说法是假的——`B5-P2-DATA.md` 的 SR-P2-6 行与覆盖句均已更正（"Batch 5 时 P2-6 无任何用例…此前'已测'的说法作废"）。
- **5 项口径落实**：(1) SR2-29 报告分布扣已掌握（`report_page.dart:184` 加 `!_isMastered(q)`，`_isMastered` 在 `:192`，与错题本同义）；(2) SR2-40 紧凑行不设行号、大卡片蓝色序号圆盘保留（`wrongbook_list.dart`：`_buildLargeCards` 传 `i + 1` 作 number，`_buildCompactRows` 不传序号）；(3) 月筛选 `age < 30`、文案"最近 30 天"（`wrongbook_page.dart:611-621`、`wrongbook_list.dart:286`），报告页"本月"自然月不动；(4) `reviewCount` 不显示——`lib/` 内仅模型/库/透传（`db_codec.dart`、`models.dart`、`question_detail_page.dart:269`），无任何页面渲染；(5) 三项裁决成立：SR-P2-66 雾化 45% 混 `#DCE3EC`（`widgets.dart:727-751` 委托 `DesignTokens.subjectColor`，SR2-36 已补）、SR-P2-51 12 色 + 金角（SR2-31 按 25° 阈值重算，`subjects_page.dart:62-63,322-333`）、SR-P2-52/55 直接通过（无代码改动）。
- **文档改动逐处核实**：SR2-8（硬判口径 3 处：边界 `:85`、D-15 `:134`、代码地图 `:478`）、SR2-9（`demoQuestions()` 已删 3 处：D-04、README、代码地图）、SR2-10（D-23 两处：空框 + `usedFallback: true`、导入已真实落盘）、SR2-39～48、SR2-50（边界 §4.2/§4.4、CODEBUDDY/四方分工/代码地图头注与测试清单、B5-DOCS/B5-SUMMARY 范围串、B5-P1-COUNTS 标题 7 项、收集组 18→17/22→21 与 P2-22 拆分口径、`done` 分支保留、B5-SUMMARY/B5-P2 的 SR2-48 已定状态、B5-P2.md:56 差额具名）及协调员收尾 6 处文档同步（B5-SUMMARY"已裁决"改写、`:23` 派生信号、CODEBUDDY 状态、四方分工"眼前第一步"、代码地图 test 清单补 `b5_p1_3_delete_exam_test.dart`、F-docs 两处遗留落实）均与文件现状一致；旧措辞残留只见于历史报告（P0B2-P1-REPORT、B3-DOCS、SELF-REVIEW-DOCS/DATA/SERVICES、S8A4-BANNER-REPORT 等，有意不动）与 `R0-REPORT.md:108`（同类历史报告）。
- **测试质量抽查（9 组，均真断言声称行为）**：SR2-55 字面值 `0xFF7CAAF2` + 暖红第二输入 `0xFFE68C90`（`toARGB32()` 对字面值，注释写明 `Color.lerp` 小数通道问题，不再与实现共用公式）；SR2-56 第 13 科字面值 `0xFFB34CD9` + 与 12 色 hue 距 ≥25°（见 DOCS-10 的同公式弱点，已兜底）；SR2-64 复查日边界 4 个断言（今天零点与此刻均落 `recheck` 桶、`isReviewDue` 为真）；SR2-73 并发测试（屏障 + `_loadAttempts` 计数；模型缺失路径无原生库也可全程断言，真实模型路径先断言共享加载再 `markTestSkipped`）；SR2-61 首页真实仓库用例（`runAsync` 内播种 + 仓储层断言先行，`pumpHome(settle: false)` + 真实时间驱动轮询，90s 超时兜底）；SR2-12 任务 id 正则 `^task-\d+-\d+-\d{6}$` + 20 次快速导入全不同（报告已明言同毫秒无法确定性安排）；SR2-13 `%` 徽章（`^\d+%$` 读数，点 ＋ 变大、点 － 变小）；SR2-77 0→70 逐个 `contains` + 长度 ≥71 + 末值 100；SR2-24 手算几何期望 `Rect(0.2, 0.2, 0.2, 0.2)`（独立于实现）。未发现"测试与实现共用公式算期望"（除 DOCS-10 已兜底的一处）、断言过弱、或只测成功路径的情形——失败路径均有触发器/损坏引擎/屏障覆盖（SR2-60、SR2-11、SR2-66、SR2-78 等）。
- **lib/ 全量 diff 扫描**：`6448c45..38cbc4b` 的 lib/ 改动（db_backup SR2-16/19、db_catalog SR2-15、db_collect SR2-27/18/注释、db_questions SR2-14、models SR2-23、box_editor SR2-37/21/20、collect_page SR2-22/62/4/25、detail SR2-3、organize SR2-6/26/5、report SR2-29、review SR2-34/33、settings SR2-30、subjects SR2-36 注释/31、wrongbook SR2-7/28/34/32/月筛选、import_service SR2-72/1/2、yolo SR2-73 串行化 + SR2-38、zip SR2-17、uikit SR2-35、widgets SR2-24/36）**全部**有报告对应；除报告已标出的 5 处偏离（SR2-60 `_dedupKey` 归一化、SR2-62 `_lastSplitStamp` 重抽、SR2-4 不钳制只补 `parentBoxId`、SR2-26 选"拦下"不选"放行"、SR2-22 选方案 (a) boxing 标志）外，**未发现未标出的产品偏离**。
- **`flutter analyze` 复跑**：全仓 `No issues found!`（45.4s），与总结一致。
- **演示库 md5**：现盘 `~/.local/share/quiz-master2/quiz-master2.db` 实测 `8f7f9c64405dc6e484ac2bf8e5e1a807`，与总结一致。
- **覆盖对账**：78 项逐项对账——77 项有 B6 报告覆盖（含 SR2-49 只留档警告），唯一缺席 SR2-57（Win11 文件锁分支，有意不做，见遗留）。
- **GPT 分流结论**：无法从仓库独立核实（主会话转达）；P1-1=SR2-3、P1-2=SR2-4、P1-3=SR2-1 图片解码子型、P1-4=SR2-2 的映射与本批内容一致，无矛盾。
- **其他核实点**：`db_collect.dart:340-343` 过时注释已由 C-data 修正；SR2-27 测试种子已按协调员要求改为 4 道不同题各 1 框（q5 覆盖另一页）；SR2-61 的 `pumpHome` 仓库参数已放宽为 `QuestionRepository?` 并加 `settle` 参数；`loadGateForTest` 只在测试内赋值，产品恒为 null；`_confirmCurrent` 自身保存确无 try（`organize_page.dart:359-377` 三处写库均无保护），遗留属实；D-07 已标"已被 D-23 取代，仅留作历史"。

## 已确认的遗留（B6-SUMMARY"遗留"小节所列，经核对属实；另见 DOCS-4、DOCS-5 补列的 8 条）

- `_confirmCurrent` 自身的保存无 try（SR2-26 没点名的第 5 处）。
- SR2-3 的重命名失败分支未测（需文件系统故障注入）；进程中途被杀留 `.tmp` 孤儿文件（孤儿扫描 §4.5 覆盖）。
- 失败行本身写不进库时，DB 任务卡在 `importing`（处方内降级，已钉测试）。
- SR2-12 同毫秒确定性覆盖需可注入时钟重构（本批范围外）。
- 旧 needBox 保留行仍靠 `_hasSplitSibling`（删拆分行后警告仍会消失——存量行的一次性处理需定）。
- SR2-19 峰值口径偏保守（最终体积 < 2GB 但峰值 > 2GB 的备份现在会被拒——Meng 如不同意需他定）。
- `_clearCache` 只删文件、留空缓存目录（下次扫描为 0，无害）。
- `toggleFavorite` / `archive` / `save` 在共享 choke 点修，未按仓库层逐列方法做（如要，另立项）。
- SR2-62 同毫秒场景未确定性覆盖。
- SR2-15 并发测试依赖 sqflite 事务串行化。
- SR2-16 对既有备份 fixture 的影响面——第三次全量已确认无回归，见 DOCS-5（应移出遗留）。
- 历史报告里的过时措辞有意不动（历史记录）。
- `double` 封面折角：Meng 自己与 CodeBuddy 协调，Muse 不做（原决定不变）。
- 检测质量（密集排版重叠框）不在本批范围；P3(b) 孤儿目标迁移（需合并语义）仍待定。
- SR2-57：P2-11 的 Windows 文件锁分支（Linux 测不了），待 Win11 真机复核；其余沿用 2026-11-14 09:15 的验收清单。
- 测试夹具 zip 链接 2026-11-16T00:41:08Z 过期（本地副本 `~/workspace/qm2-test-fixtures.zip` 可重传）。
