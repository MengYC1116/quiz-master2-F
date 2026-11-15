# Batch 6 第二批 P2：收集 / 整理 / 详情 — 执行员 D-collect 报告

- 工作树 `~/workspace/quiz-master2-UI`，分支 `ui-replication`；未 commit、未 push，未动 git 历史。
- 范围：SR2-20、SR2-21、SR2-22、SR2-23、SR2-37（代码），SR2-51、SR2-62（测试），另补 SR2-21 对照用例与 SR2-23 直接单测；附加：B5-P2.md / B5-P2-COLLECT.md 的 `_hasSplitSibling`“持久化信号”措辞修正。
- 改动文件：`lib/modules/collect/box_editor.dart`、`lib/modules/collect/collect_page.dart`、`lib/models/models.dart`、`test/b5_p2_collect_test.dart`、`docs/ui-replication/B5-P2.md`、`docs/ui-replication/B5-P2-COLLECT.md`。未碰其他执行员的文件。

## 1. 逐项结果

| 项 | 结果 |
|---|---|
| SR2-20 重框“恢复自动框”只认第一道题级框 | 已修：按 `questionId` 选目标框，逐个 IoU 匹配替换（贪心认领，检测框只用一次）；附多框测试。 |
| SR2-21 “恢复自动框”手动判断查了全部页 | 已修：`hasManual` 只查当前页；附“手画框在别页”对照测试。 |
| SR2-22 `_hasSplitSibling` 是派生信号 | 已修：保留任务重建直接写 `boxing` 状态，警告不再依赖拆分任务行；`_hasSplitSibling` 保留作旧行兜底；附端到端测试。 |
| SR2-23 `allCauses` 不去重 | 已修：getter 内保序去重；附直接单测。 |
| SR2-37 `_loadPageImageSize` 不 dispose Codec | 已修：与已修两处同款 `try/finally` 里 `codec.dispose()`。 |
| SR2-51 SR-P2-21 只测“点空白退出” | 已补：先点框体断言仍在内框模式，再点空白断言退出。 |
| SR2-62 两次确认撞同一毫秒未实测 | 已补：同一用例内连续确认两次，断言随机段不同、题 id 无交集；另加同毫秒撞戳重抽兜底（见 §3）。 |
| 附加：B5 文档“持久化信号”措辞 | 已改两处（见 §4）。 |

## 2. 改动明细（文件:行）

### SR2-20 — `lib/modules/collect/box_editor.dart:715-816`（`_restoreAutoBoxForRework` 重写）

- 目标框不再拿题 id 跟框 id 比：`targetId = widget.reworkQuestionId`（题 id）→ 目标框 = `questionId == targetId` 的 1 层框；框上没填 `questionId`（旧草稿/测试桩）时回退到全部 1 层框（重框模式下当前页本就只有目标题的框）。
- 逐个目标框做 IoU 匹配：全部候选（IoU > 0.05）按 IoU 从大到小贪心认领，每个检测框只用一次，避免两道题抢到同一个检测框；每道匹配上的框按旧逻辑换坐标、其内框按新旧框相对位置跟随并钳进新框。
- 部分匹配时：已恢复的照常生效，没恢复的留在原位，弹提示“有 N 道框没找到对应的检测框，已恢复其余框，请手动框选”；一道都没匹配上时仍报旧文案“没找到对应的题，请手动框选”。
- 测试 `test/b5_p2_collect_test.dart:583`：两道 1 层框（`b1`/`b2`，`questionId` 均为 `q1`，框 id 永不等于 `reworkQuestionId`）各挂一个内框，检测框各向右移 0.05；恢复后 `b1 → (0.1, 0.1)`、`b2 → (0.6, 0.1)`，内框 `s1 → (0.15, 0.15)`、`s2 → (0.65, 0.15)`，且不弹“没找到对应的题”。旧代码下 `b2` 会原地不动，本用例失败。

### SR2-21 — `lib/modules/collect/box_editor.dart:647-668`（`_restoreAutoBoxes` 的 `hasManual`）

- 只查当前页：`_boxes`（本就是当前页）+ `_inners` 中 `'$page:'` 前缀的键 + `_standaloneInner[page]`；跨页的 `_inners.values` / `_standaloneInner.values` 不再参与。
- 测试 `test/b5_p2_collect_test.dart:475`（新增，SR-P2-19 组）：第 2 页有手画题内框（`_inners` 跨页键 `2:b2`），第 1 页只有 YOLO 框；在第 1 页点“恢复自动框”不弹确认、检测直接跑（`yolo.calls == [1]`）。旧代码下会误弹确认。

### SR2-22 — `lib/modules/collect/collect_page.dart:669-684`（`_confirmSplit` 保留任务重建）

- 修法选的是任务书第一种：保留任务重建时直接写 `status: CollectStatus.boxing`，不再重置回 `needBox`。`boxing` 就是“已打开过修框”的持久化标志（`_openBoxEditor` 打开时置为 boxing 并落盘，无 schema 改动、无新字段）；保留任务只可能由编辑器确认产生、必定打开过，所以直接写 `boxing`，不依赖调用方传进来的状态值。
- 附带影响（均属语义正确，无额外改动）：保留任务行上按“修框中”显示——文案“修框中 · 上次修到一半，点「继续修框」接着修”正合此态，操作按钮由“修框”变为“继续修框”，顶栏计数与筛选由“待框选”归入“修框中”。`_load` 的未框页统计本来就同时覆盖 needBox 与 boxing，不受影响。
- `_hasSplitSibling` 未删，仍在 `_load` 里派生（`collect_page.dart:121-130` 字段注释已改写：明确这是派生信号、每次重算、无字段落盘）；它现在只为修前已重建回 needBox 的旧保留任务兜底。`_taskRow` 的警告注释（`:1221-1227`）与 `_confirmSplit` 头注（`:465-468`）同步改写。
- 测试 `test/b5_p2_collect_test.dart:1284`：两页 PDF 任务、第 2 页无框 → 确认（点“确认拆题”）→ 断言 `confirmedRetainedTask.status == CollectStatus.boxing` 且只拆出 1 道题；随后把全部同源拆分任务行从桩 repo 里删掉、重进列表，保留任务仍显示“还有 1 页没有框：第 2 页”。
- 为让该用例有鉴别力，`_CollectFakeRepo.confirmSplit`（`:1219-1243`）改为模拟真实提交：原任务删掉、保留任务与拆分任务入表、已确认页草稿清掉、只留保留任务未框页草稿（否则未框页草稿不存在时警告仍会靠 `_hasAnyDraftBox` 通过，测不到 boxing 状态）。`confirmSplitShouldThrow` 时仍在应用前抛错，失败用例不受影响。`pumpPdf2` 加 `leavePage2Unboxed` 参数（默认 false，既有用例行为不变）与“确认拆题”对话框处理；轮询里加了成功提示条（“已生成”）早停，成功路径不再空转满 8 秒。

### SR2-23 — `lib/models/models.dart:345-348`

- `allCauses` 改为 `{...errorTypes, ...customErrorTypes}.toList()`：Dart Set 保序（先固定、后自定义），一处修、全链路（详情页信息区/复习记录区、错题本紧凑行）受益。
- 测试 `test/b5_p2_collect_test.dart:954`（纯单测）：`errorTypes: [计算错误, 其他]` + `customErrorTypes: [其他, 看错单位]` → `allCauses == [计算错误, 其他, 看错单位]`。

### SR2-37 — `lib/modules/collect/box_editor.dart:421-447`（`_loadPageImageSize`）

- `instantiateImageCodec` 后加 `try/finally { codec.dispose(); }`，与 `page_image_pipeline.dart:212-218` 的 `_decode` 同款；`getNextFrame` 抛错时 `finally` 同样释放；`return` 路径（已切页/已卸载）同样走 `finally`。`frame.image` 的原有 dispose 位置不变。

### SR2-51 — `test/b5_p2_collect_test.dart:686-708`（SR-P2-21 组既有用例内补）

- 进入内框模式后先在框中心（画布相对坐标 `(0.35, 0.25)`，落在题干/选项内框上）点一次鼠标左键，断言仍在内框模式（`已进入题级框` 仍在）；再点画布中心空白处，断言退出。生产代码不用改：`_canvas` 祖先 Listener 里 SR-P2-21 的修复已用 `_pointHitsInteractive` 守门，点框/缩放柄不退出。

### SR2-62 — `test/b5_p2_collect_test.dart:1308-1330` + `lib/modules/collect/collect_page.dart:453-457,537-542`

- 测试：同一用例内连续确认两次（两次 `pumpPdf2`，各走一次完整确认流程），断言两次的随机段不同、两批题 id 无交集。
- 另加生产兜底（见 §3）：`_lastSplitStamp` 静态戳 + 撞戳重抽。

## 3. 与规定修法有出入处（均有原因）

1. **SR2-22 未采用“删拆分任务时不同步影响警告判断”的第二种修法**，采用第一种（保留任务重建带上 boxing 标志）。原因：第二种修法仍需一个不受拆分任务行影响的持久化信号，而现有字段里只有 boxing 状态能承担；第一种修法不改 schema、不新增查询，且保留任务的“修框中”文案与按钮语义本就贴合该状态（见 §2 SR2-22 附带影响）。`_hasSplitSibling` 保留作旧行兜底——修前已重建回 needBox 的旧保留任务仍靠它警告（删拆分任务行后仍会消失，这是存量行的已知残留，见 §5）。
2. **SR2-62 在生产代码里多加了 6 行防撞戳**（`_lastSplitStamp` + 撞上重抽，`collect_page.dart:453-457,537-542`）。原因：自审给出的第一个选项（同一用例连续确认两次断言随机段不同）只能断言可观测性质，不能确定性覆盖“同一毫秒”——两次确认在墙钟上通常差数秒，`ts` 本就不同，随机段不同是 1-1e-6 概率事件而非保证。重抽循环把同毫秒撞 id 的概率从 1e-6 降为 0（静态戳只记上一次的 `ts-rnd`，不作他用；循环期望抽取次数 ≈1，几乎不可能多抽）。测试本身按自审选项一写，不依赖注入时钟。
3. **SR2-20 的部分匹配提示**：规定修法只说“逐个目标框做 IoU 匹配替换”，未定部分匹配时的提示。本实现：全部未匹配上报旧文案，部分未匹配报“有 N 道框没找到对应的检测框，已恢复其余框，请手动框选”，避免用户误以为全没恢复。
4. **SR2-21 与 SR2-23 各多补了一个测试**（任务书只点了 SR2-51、SR2-62 的测试）：SR2-21 的对照用例（自审正文点名缺失）、SR2-23 的 getter 直接单测（3 行）。均在同一测试文件内，无新增文件。

## 4. 附加：B5 文档“持久化信号”措辞修正（与 SR2-22 同根）

- `docs/ui-replication/B5-P2.md:27`：“补 `_hasSplitSibling` 持久化信号”→“补 `_hasSplitSibling` 派生信号，由现存同源拆分任务行派生；SR2-22 起保留任务重建直接写 boxing 状态，不再依赖它”。
- `docs/ui-replication/B5-P2-COLLECT.md:52`（任务书称 `:6`，实际出现处在 `:52`，行号已漂移）：“补了一个持久化信号”→“补了一个派生信号（每次由当前任务表重算，没有字段落盘，不是持久化信号；SR2-22 起保留任务重建直接写 boxing 状态，不再依赖它）”。
- 同文件 `:18` 表格行只写“另补信号”，无“持久化”字样，未动。
- 另发现同款措辞还在 `docs/ui-replication/B5-SUMMARY.md:23`（“补 `_hasSplitSibling` 持久化信号”），不在本次指派的两处之内，未动，请协调员或文档工人同步改一句。

## 5. 测试证据与遗留问题

### 验证

- `flutter analyze lib/models/models.dart lib/modules/collect/box_editor.dart lib/modules/collect/collect_page.dart test/b5_p2_collect_test.dart`：**0 问题**。
- `flutter test --concurrency=1 test/b5_p2_collect_test.dart`：**未跑通——环境失败，非代码失败**。VM 疑似刚被替换，clang/ninja 已丢失，测试在 `pdfium_dart` 原生资源构建处失败：`No compiler configured on host 'linux_x64' with target 'linux_x64'`（`System not configured correctly`）。按任务要求只试跑一次以确认环境失败，未自行修复工具链（不下载、不安装、不跑恢复脚本）。本文件新增/改动的 5 个用例（SR2-20 多框、SR2-21 别页对照、SR2-22 保留任务、SR2-62 两次确认、SR2-23 单测）与改动的 SR-P2-21 用例均未经 live 运行；**阶段关口的全量验证等工具链恢复后由总协调补跑**。
- 新增/改动用例的正确性目前只经过代码走读复核：SR2-20 的内框跟随坐标（`s1 → (0.15, 0.15)`、`s2 → (0.65, 0.15)`）按 `_restoreAutoBoxForRework` 的相对位置换算式手算过；SR2-22 的警告文案按 `_noBoxWarningText`（`pageCount=2`、未框 `[2]` →“还有 1 页没有框：第 2 页”）核对过；SR2-51 的点框坐标按画布线性映射与 `_pointHitsInteractive` 的命中规则核对过（框中心落在内框上，祖先 Listener 不退出）。

### 遗留问题

1. **SR2-22 存量行残留**：修前已重建回 `needBox` 的旧保留任务，警告仍只靠 `_hasSplitSibling`；删掉全部同源拆分任务行后警告仍会消失。新确认产生的保留任务不再有此问题。是否要对存量行做一次性处理（如重进列表时把带拆分兄弟的 needBox 保留任务改写为 boxing），需协调员/Meng 定——本次未动存量数据。
2. **SR2-62 的“同一毫秒”场景仍未被确定性跑到**：两次确认在墙钟上差数秒，测试断言的是可观测性质；同毫秒防撞靠 `_lastSplitStamp` 重抽循环保证（代码走读），未被强制同毫秒的单测覆盖。如需确定性覆盖，需把戳生成抽成可注入时钟的纯函数，属生产代码重构，本次未做。
3. **B5-SUMMARY.md:23 同款措辞未改**（见 §4），请协调员同步。
4. 本批改动均未提交、未推送。
