# 第三次自审 — 收集 / 整理 / 详情（COLLECT）

- 审阅员：收集/整理/详情审阅员
- 日期：2026-11-15
- 范围：只审第六批改动（B6），文件：`lib/modules/detail/question_detail_page.dart`（SR2-3）、`lib/modules/collect/collect_page.dart`（SR2-4 / SR2-25 / SR2-22 / SR2-62）、`lib/modules/collect/box_editor.dart`（SR2-20 / SR2-21）、`lib/modules/organize/organize_page.dart`（SR2-5 / SR2-6 / SR2-26），及相关测试。只审、不改代码；未提交、未推送。
- 依据：`docs/ui-replication/B6-P1-DETAIL.md`、`B6-P1-SPLIT.md`、`B6-P1-QUEUE.md`、`B6-P2-COLLECT.md`、`B6-SUMMARY.md`；逐段核对产品代码，辅以探针（`dart` 随机数探针）与测试重跑。
- 结论：**P0 0 项、P1 0 项、P2 7 项**。第六批没有引入丢数据/崩溃级问题；7 项均为 P2（边界、失败路径、提示准确性）。

## COLLECT-1（P2）SR2-3：事务成功、rename 前进程被杀，DB 与磁盘切片不一致且无自愈

- 位置：`lib/modules/detail/question_detail_page.dart:397-429`（`_reworkBoxes`）。
- 现象：事务提交（框 + `slicePath`/`sliceWidth`/`sliceHeight` 已是新值）与 `File(tmpAbs).rename(sliceAbs)`（`:417`）之间没有原子性保障。进程恰好死在这两步之间时，库里记的是新切片的尺寸与路径，磁盘上的 `slices/<qid>.png` 仍是**旧图**。下次打开详情页，题按新尺寸展示旧图；没有任何代码会发现或修复这种不一致。
- 证据：
  - 事务成功后 rename 前无任何持久化标记（如 generation / 校验），失败/中断后无法区分“旧图 + 新框”是合法状态还是中断残留。
  - 孤儿扫描（`lib/data/db_orphans.dart`）不覆盖此情形：旧切片仍被 `slice_path` 引用，不是孤儿；临时文件 `.tmp-*` 是孤儿（见“已确认”），但旧图不是。
  - 残留的 `.tmp` 文件本身会被扫描发现，但它救不了“库已新、图仍旧”的不一致——删掉 `.tmp` 后旧图照样顶着新尺寸被展示。
- 修的方向：任选其一：(a) 启动/打开详情页时校验切片实际尺寸与库里 `sliceWidth/sliceHeight` 是否一致，不一致时按当前框重裁一次（或提示重框）；(b) 把“已 rename”做成可恢复的两阶段提交（如先把 `.tmp` 路径也写进一个待处理标记，启动时对有标记的题补做 rename）；(c) 至少在文档/复核清单里把“事务提交后、rename 前被杀”记为已知崩溃窗口，与 `.tmp` 孤儿分开列（目前 B6 只认了 `.tmp` 孤儿这一半）。

## COLLECT-2（P2）SR2-3：`_reworkBoxes` 里读页图与裁切片在 try 外，失败时无提示、无反馈

- 位置：`lib/modules/detail/question_detail_page.dart:361-363`，调用点 `:1340`（`onPressed: _reworkBoxes`，无 try）。
- 现象：`File(pageAbs).readAsBytes()`（`:361`）与 `cropBoxPng(pageBytes, first)`（`:363`）都不在 try 里。页图存在但读不出（权限/IO 错误、文件损坏截断）或框落在图外时，异常直接抛到按钮回调：无 SnackBar、用户看不到任何反馈，本次重框会话（编辑器里刚改好的框）白做，只能重进编辑器再改一遍。库本身不受影响（事务还没跑），所以只是 P2。
- 证据：
  - `cropBoxPng` 明确会抛：`lib/services/page_image_pipeline.dart:158-160`，裁后宽/高 ≤ 0 时抛 `ArgumentError('框 … 落在页图外，裁不出切片')`；`_decode`（`:211`）在页图字节损坏时同样会抛。
  - 同一段里临时文件写盘有 try/catch（`:380-386`，报“切片写不进去”），事务失败有 try/catch（`:403-410`），rename 失败有 try/catch（`:417-427`）——唯独读图 + 裁切这两步没有，形成不对称缺口；B6-P1-DETAIL.md 称该段“整段按规定修法重写”，缺口是重写时留下的。
- 修的方向：把 `:361-363`（含 `resolveDataPath` 判空后的读 + 裁）包进 try/catch，失败报“重新框选失败：页图读不出来/切片裁不出来，请重试”并 return；补一个用例：用损坏页图字节（或 `cropBoxPng` 抛错的桩）断言提示出现且 `takeException()` 为空。

## COLLECT-3（P2）SR2-4：中心点挂接在框重叠时平局静默取先到者，且无距离上限

- 位置：`lib/modules/collect/collect_page.dart:768-795`（`_nearestLayer1Box`），调用点 `:630-645`。
- 现象：
  1. **重叠平局**：独立内框中心同时落在两个重叠的 1 层框内时，两个距离都是 0，`d < bestDist` 的严格小于使列表先到的框静默获胜，没有任何提示或二次判据。密集排版下框重叠是已知高频情形（验收清单里单列的检测质量问题），“挂错题”就发生在这个最常见的场景里。
  2. **无距离上限**：只要本页有 1 层框，函数必返回一个框，哪怕独立内框中心离所有题都很远（如页眉/页边手画的 stray 框）。以前这种框在确认时被丢弃（可见的丢失），现在会被静默挂到最近的题下（不可见的错挂）。
- 证据：`_nearestLayer1Box` 无距离阈值、无面积/相交度比较；平局只靠 `for` 循环顺序（画框/检测顺序），与框的语义无关。`_confirmSplit` 里对 `target == null` 的 `continue`（`:640`）在 `layer1` 非空时永远走不到，等于是“必挂”。
- 修的方向：平局/重叠时改判据为内框与候选框的相交面积最大者（或面积最小的命中框），仍平局时把该内框留在 `standaloneInner` 并在确认后提示“有 1 个题内框同时落在两道题里，请手动指定归属”；另加距离上限（如中心到框的最短距离超过页宽/高的 0.25 即不挂，确认后提示用户手动处理），避免远处 stray 框被强制归属。

## COLLECT-4（P2）SR2-20：候选检测框池未过滤 + IoU > 0.05 阈值过低，邻题检测框可把目标框拽走且不提示

- 位置：`lib/modules/collect/box_editor.dart:715-816`（`_restoreAutoBoxForRework`），候选池与阈值约 `:750-760`，部分匹配提示约 `:795-800`。
- 现象：`detected` 取的是本页**全部** 1 层检测框（含同页其他题的框——重框模式下只读框就在同一页上），而 `targets` 只有当前题的框。某目标框的真实检测缺失时，只要邻题的检测框与它有 > 0.05 的 IoU，就会按贪心认领把它“恢复”到邻题的位置上；`matches` 计入该目标，`missed` 不增加，用户收不到“没找到对应的检测框”提示，框错位要靠肉眼发现。
- 证据：
  - 阈值 0.05 极低：一个角上轻微搭边的检测框即可认领，换算后目标框整体跳到检测框几何上（`list[i] = newBox`），位移可达半页以上。
  - 贪心按 IoU 降序虽能防止两道题抢同一个检测框，但防不住“目标 A 的真实检测缺失 → 邻题检测框与 A 有微弱重叠 → 被 A 认领”；邻题的检测框本来就该由邻题的目标认领，但邻题在重框模式下不是 target，不参与认领，池子却对它开放。
- 修的方向：二选一或并用：(a) 提高阈值（如 0.3，并在提示里说明阈值）；(b) 候选池排除中心落在其他题只读框内的检测框（重框模式下 `widget.readOnlyBoxes` 已有）；(c) 认领后校验位移，中心位移超过阈值时视为未匹配、按 missed 提示。补用例：双题同页、一题检测缺失、邻题检测框与目标框微弱重叠 → 断言目标框不动且弹“没找到对应的检测框”提示。

## COLLECT-5（P2）SR2-20：恢复自动框时独立题内框不跟随 1 层框移动

- 位置：`lib/modules/collect/box_editor.dart:715-816`（`_restoreAutoBoxForRework` 的 `setState` 段），对比 `lib/modules/detail/question_detail_page.dart:332-336`（详情页把无父框内框传进 `initialStandalone`）。
- 现象：恢复时只有 `_inners[key]`（有父框的内框）按新旧框相对位置换算跟随（并 `_clampInner` 钳进新框）；`_standaloneInner` 里的无父框内框原地不动。重框模式下这些独立内框本就属于当前题（详情页按 `questionId == q.id` 挑出来传进来的），1 层框平移/缩放后它们与题的相对位置全错。
- 证据：`setState` 段只处理 `_inners[key]`，全文无对 `_standaloneInner` 的写操作。后果分两支：多题同页时，确认拆题的 SR2-4 会按**新**中心点重新挂接，错位后的内框可能被挂到邻题下（COLLECT-3 的挂错在确认时二次放大）；单题页则区域换算（`layer2BoxToSliceRect`）按错位坐标算，内框被钳到切片边缘或直接无面积回退示意框。
- 修的方向：对中心落在旧目标框内的独立内框做与 `_inners` 相同的相对位置换算（或至少整体平移同一 delta），再 `_clampInner` 钳进新框；中心落在旧框外的独立内框保持不动。补用例：重框恢复后断言独立内框随 1 层框同向移动。

## COLLECT-6（P2）SR2-5：`_batchTagRedo` 的快照同步是全有或全无，循环中途写库失败会让已落盘的标签被后续批量操作抹掉

- 位置：`lib/modules/organize/organize_page.dart:2286-2306`（`_batchTagRedo`）。
- 现象：保存循环（逐题 `repo.save`）没有任何 try；同步回 `_questions` 的 `setState` 只在整个循环成功后执行。循环中途某题写库失败抛错时，前面已保存的题在库里已有 `#需重做`，但弹窗内的 `_questions` 仍是旧行；用户随后在同一弹窗里做批量加文件夹/批量确认（整行覆盖），就会把刚落盘的标签抹掉——正是 SR2-5 要根治的那种抹除，只是换了一条触发路径（失败路径）。
- 证据：`_batchTagRedo` 的 `setState` 在循环之后、无 `try/finally`；`_batchAddFolder` 是同款结构（旧有），但 B6 的修复恰恰依赖“保存后同步”这一步必跑，失败路径下它不跑。注意 `_saveCurrent`/`_trySaveCurrent` 的调用方拦停逻辑管不到弹窗内的批量路径。
- 修的方向：每保存成功一题就地同步该行进 `_questions`（循环内 `setState` 或先改本地副本、循环结束统一 `setState` 一次并用 `try/finally` 保证执行）；或失败时把已保存的题 id 记下来、同步已保存子集并提示“部分保存失败”。补用例：桩 repo 第二题 `save` 抛错 → 断言第一题的标签在弹窗快照里仍在、后续批量加文件夹后标签不丢。

## COLLECT-7（P2）SR2-26：“拦住”只拦 6 处页内动作，离页路径不保存，持续保存失败时用户仍可走出页面并静默丢编辑

- 位置：`lib/modules/organize/organize_page.dart:334-344`（`_trySaveCurrent`）、调用点 `:345/352/382/401/460/476`；离页路径见 `:150-160`（`dispose` 只 dispose 控制器）与全文件无 `PopScope`/`WillPopScope`。
- 现象：B6-P1-QUEUE.md 论证“拦住”时称“改动真正留在内存里……行为与提示一致”，但这只在用户留在整理页内成立。保存持续失败（如写库一直抛错）时，用户在页内确实切不了题、开不了队列、进不了详情，但点左导航/返回即可离页；离页时没有任何保存尝试与未保存提示，表单改动静默丢失——“拦住”防的是页内静默丢，没防住离页静默丢。
- 证据：
  - 6 处调用点（`_saveDraft` / `_goTo` / `_openDetail` / `_openQueue` / `_jumpToQuestion` / `_applyQueueSort`）全部正确处理了 `false`（逐个核对，无忽略返回值的调用点）；但 `_confirmCurrent`（`:359`，已知遗留）与离页路径不在此列。
  - `dispose`（`:150-160`）只释放控制器，不调 `_saveCurrent`；全文件无 `PopScope`/`WillPopScope`，`app_shell` 侧也无针对整理页的离页拦截。
- 修的方向：给整理页加离页守卫（`PopScope` + 切导航前尝试保存；保存失败时弹“有未保存的改动，保存失败，仍要离开吗？”由用户决定去留），或至少在 B6-P1-QUEUE.md 的“拦住”论证里补一句适用边界（只保页内动作，不保离页）。后者是文档级修正，前者是产品级修正；按 Meng 的“拦住”定调，建议先文档，后者另立项由 Meng 定。

## 已确认无问题

- **SR2-3 临时文件命名冲突**：`'slices/<qid>.tmp-<ms>-<32-bit random>.png'`（`question_detail_page.dart:374-376`）。探针实测：10 万次新建 `math.Random()` 首抽 `nextInt(1 << 32)` 零重复，种子不相关；同一题的重框是模态对话框串行的，不存在两个临时文件同时活着且同名的时间窗口；不同题有不同 `qid` 前缀。冲突概率可忽略，无问题。
- **SR2-3 重命名失败后旧切片与框状态**：rename 失败分支（`:417-427`）删临时文件、保留旧切片，提示“切片保存失败，框已更新，请重试”，不谎称全失败；且该分支**不**调 `evictCachedFileImage`（正确，旧图仍有效，缓存语义没断）。`evictCachedFileImage` 已移到 rename 成功后（`:428`）。无问题。
- **SR2-3 `.tmp` 孤儿是否被孤儿扫描覆盖**：已确认覆盖。`lib/data/db_orphans.dart` 的 `scanOrphanFilesFromImpl` 递归扫 `slices/`，引用集合只含 `slice_path` 等正式路径，`.tmp-*` 文件永不在引用集里，必被列为孤儿。唯一 caveat：扫描是设置页手动触发，残留文件会一直留到用户手动扫一次；且扫描无“进行中”保护，理论上可在重框进行中的毫秒级窗口内把活 `.tmp` 列为孤儿——窗口极小、需用户恰好同时在设置页点扫描，可接受，不编号。
- **SR2-3 rename 覆盖已存在目标（Windows）**：当前 Dart SDK（3.13，随 Flutter 3.47.9）`File.rename` 文档明确写“目标是已存在的文件或链接时，该实体先被移除”（`dart-sdk/lib/io/file.dart:281-283`），即覆盖行为是 SDK 保证的；Linux 上 `rename(2)` 本就原子替换。Windows 原子性未在真机上验证，建议放进 Win11 真机复核清单核对一次，不编号。
- **SR2-4 跨页**：`standaloneInner[p]` 只与当页 `layer1` 匹配（`collect_page.dart:630-645`），无跨页串题。无问题。
- **SR2-4 不钳制的下游安全**：`layer2BoxToSliceRect`（`lib/widgets/widgets.dart:59-69`）把超框部分夹到 0..1、无面积返回 null，`realRegionRects` 跳过 null 并回退示意框；手画几何原样保留不越界、不崩。无问题。
- **SR2-4 入库路径**：挂接的内框经 `boxesByQuestionId[targetQid]` 入库，`confirmSplitIntoImpl`（`lib/data/db_collect.dart:486-500`）按 map 的 key 用 `copyWith(questionId: q.id)` 回填，与原有 parented 内框同一条路；`QuestionBox` 无 `==` 重写，`layer1.indexOf(target)` 是同一对象查找，不会错指。无问题。
- **SR2-20 贪心 IoU 匹配与部分匹配提示**：`box_editor.dart:715-816`。贪心按 IoU 降序、每个检测框只用一次；`missed = targets.length - matches.length` 计数准确——`_boxes` 即 `_boxesByPage[_currentPage]` 同一对象（`:329-330`），`indexWhere` 不会落空，`matches` 无虚报；“全部未匹配报旧文案、部分未匹配报‘有 N 道框没找到……已恢复其余框’”的文案与行为一致。无问题。措辞小瑕疵（不编号）：`N` 数的是 1 层框个数，文案却说“N 道框”，“道”通常指题；一题多框时易误读，建议改为“N 个框”。
- **SR2-20 回退口径**：`questionId` 缺失时回退到全部 1 层框——重框模式下 `_boxes` 只有目标题的框，只读框在 `widget.readOnlyBoxes` 里另存、不进 `_boxes`（`box_editor.dart:369` 只用于重叠校验与绘制），回退不会动到别题的框。无问题。
- **SR2-21 `hasManual` 只看当前页**：`box_editor.dart:647-668`。`_boxes` 本就是当前页；`_inners` 用 `'$_currentPage:'` 前缀过滤（`'11:…'.startsWith('1:')` 为 false，不会把第 11 页误算进第 1 页）；`_standaloneInner[_currentPage]` 直接按键取。无问题。
- **SR2-22 boxing 标志与警告一致**：保留任务重建直接写 `boxing`（`collect_page.dart:669-684`），与 `_openBoxEditor` 打开时置 `boxing` 并落盘（`:389-390`）是同一信号；行上警告条件 `warnUnboxed`（`:1221-1229`）含 `status == boxing`，删掉全部同源拆分任务行后警告仍在；`_hasSplitSibling` 只留作旧 needBox 行兜底（注释已同步改写）。无问题。
- **SR2-25 尾部 `saveRecentTask` 包 try**：`collect_page.dart:729-736`。失败只 `debugPrint` 后继续 `_load()` 与成功提示，拆题事务不受影响；测试断言列表刷新与无未处理异常。无问题。
- **SR2-62 `_lastSplitStamp` 碰撞重抽**：`collect_page.dart:457-542`。逻辑正确：戳比较与重抽在两次确认之间无 `await`（单线程内不可交错）；首次确认时 `_lastSplitStamp` 为空串永不撞；失败的确认会消耗一个戳，无害（只是跳过一个值）；探针证实 `Random()` 首抽不相关，重抽循环不会空转。无问题。
- **SR2-5 / SR2-6 本体**：`_batchTagRedo` 保存后同步 `_questions`（`organize_page.dart:2286-2306`），`_saveCurrent` 成功后把 `_formQuestion` 的返回值写回 `_queue`（`:313-327`），`_openQueue` 的 B5 单点补丁已删——主路径闭合，测试回滚验证 8/8 失败。无问题（失败路径见 COLLECT-6）。
- **SR2-26 各调用点返回值处理**：6 处调用点全部 `if (!await _trySaveCurrent()) return;`，无忽略返回值的调用点；`_saveDraft` 成功才报“草稿已保存”（`:344-348`），失败只报“保存失败，请重试”，不再谎报。无问题（离页缺口见 COLLECT-7）。
- **B6-SUMMARY “过时测试已删除、留注释指向 SR2-24 分组”属实**：`test/b5_p2_collect_test.dart:266-268` 留注释说明旧用例已被 SR2-24 推翻、覆盖在 `test/b5_p2_services_test.dart` 的 SR2-24 组（`:744`）；旧用例文案“第 2 个 1 层框下的题内框按该框换算”在全文件无残留；同组 `parentBoxId` 为空的兜底测试仍在。属实。

## 已确认的遗留（B6-SUMMARY 已列，不重复编号）

- `_confirmCurrent` 自身的保存（`organize_page.dart:359-377`：`repo.save` + `syncCauseRecords` + `saveRecentTask`）仍无 try——保存失败直接抛到按钮回调、无提示。已确认仍在。
- SR2-3 重命名失败分支未测（需文件系统故障注入）。已确认仍在；另补充：Windows 上 rename 覆盖的原子性也未在真机验证，建议并入 Win11 复核清单。
- 旧 needBox 保留行仍靠 `_hasSplitSibling`（`collect_page.dart:121-130`）：删拆分行后警告仍会消失——存量行的一次性处理需定。已确认仍在。
- SR2-62 同毫秒场景未确定性覆盖：两次确认在墙钟上差数秒，测试断言的是可观测性质；本次探针只证实了 `Random()` 首抽不相关，未覆盖“同一毫秒 + 同随机段”的强制分支。已确认仍在。
- B6-P1-QUEUE.md 的另一处遗留（`_jumpToQuestion` 失败时弹出层已先关，用户需重开队列再跳）已确认仍在，属可接受的轻微体验代价，不编号。

## 测试证据

- 探针：`/tmp/rnd_probe.dart`（已删）：10 万次新建 `math.Random()` 首抽 `nextInt(1 << 32)` 零重复；模拟 SR2-62 重抽循环 1000 次，总自旋 0、最大自旋 0。
- 回归重跑（串行 `--concurrency=1`，`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`）：`test/detail_page_test.dart`、`test/collect_page_test.dart`、`test/organize_page_test.dart`、`test/b5_p2_collect_test.dart`、`test/b5_p1_256_test.dart` 五个文件一次跑完，**153/153 通过**（`All tests passed!`，约 222 秒）。未跑全量测试。
