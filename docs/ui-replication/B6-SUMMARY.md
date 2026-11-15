# Batch 6 总结 — 第二次自审 78 项修复

- 任务：修完第二次自审（SELF-REVIEW-2.md / SELF-REVIEW-2-SUMMARY.md）的全部 78 项（P0 0、P1 13、P2 65）。
- 日期：2026-11-15。协调员 f857c534。
- 基线：Batch 5 完成（`flutter analyze` 0 问题；全量测试 778/778；Linux Release 构建通过；演示库 md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`）。
- 原则：只修第二次自审列出的问题；Meng 已定的 5 项口径按决定执行；不提交、不推送（推送须 Meng 另外批准）。

## 最终验证

- `flutter analyze`：**0 问题**（`No issues found!`）。
- 全量测试：串行 `--concurrency=1`，`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`，**852/852 通过**（第三次全量；第一次全量 9 失败与第二次全量 5 失败均已修掉并重跑验证，见“协调员收尾修复”）。
- Linux Release 构建：通过（`✓ Built build/linux/x64/release/bundle/quiz_master2`）。
- 演示库：跑全量前后 md5 均为 `8f7f9c64405dc6e484ac2bf8e5e1a807`（v1、9 道题、3 学科），未变。
- 计数演进：778（Batch 5）→ **852（Batch 6，净增 74）**。

## 阶段 A：P1 数据丢失 / 回归（6 组并行）

### A-import — SR2-1、SR2-2、SR2-12、SR2-60、SR2-71、SR2-72（`B6-P1-IMPORT.md`）

- SR2-1：图片分支尾部 upsert 包进与 PDF 分支相同的 `_failAndClean` 保护；`enqueue` 外层加 per-file try；EXIF 分支区分“解不出图”（永不回 needBox）与“磁盘失败”。
- SR2-2：`_failAndClean` 自身的写库加守卫；9 个调用点只有尾部一个受保护的问题已消除。
- SR2-12：任务 id 格式正则 `^task-\d+-\d+-\d{6}$`，20 次快速导入 id 全不同。同一毫秒确定性覆盖做不到（无可注入时钟），20 次快速调用是最强覆盖。
- SR2-60：`_dedupKey` 归一化（解析符号链接 + 小写）——超出原处方的一处产品改动，已在报告中标出。
- SR2-71：20MB 边界用例；SR2-72：同文件不同拼写（大小写/符号链接/相对路径）去重。
- 验证：`import_service_p1_fixes_test` 16/16；`b5_p2_services_test` 15/15。
- 遗留：失败行本身写不进库时，DB 里的任务仍卡在 `importing`（处方内的降级行为，已有测试钉住）。

### A-detail — SR2-3（Batch 5 新回归，`B6-P1-DETAIL.md`）

- 详情页重框：新切片先写临时文件 `slices/<qid>.tmp-<ms>-<32-bit random>.png`，事务成功后才重命名为正式路径；`evictCachedFileImage` 移到重命名之后；重命名失败报“切片保存失败，框已更新，请重试”，旧切片不丢。
- 验证：`detail_page_test` 28/28（含新增旧切片场景）。
- 备注：`replaceQuestionBoxesAndSlice` 实际在 `db_collect.dart:325`（不在 `db_questions.dart`）；`db_collect.dart:340-343` 注释（“切片由调用方在事务前写盘”）已过时——C-data 阶段已随手修正；B5 的 P2-3 回归测试实际在 `test/b5_p2_collect_test.dart`（约 :891-960），不在 detail_page_test。
- 遗留：重命名失败分支未测（需文件系统故障注入）；进程在中途被杀会留 `.tmp` 孤儿文件（孤儿扫描 §4.5 覆盖）。

### A-split — SR2-4、SR2-11、SR2-25（`B6-P1-SPLIT.md`）

- SR2-4：有框页的独立题内框按中心点挂到最近/命中的题下（`_nearestLayer1Box`，框内中心距离 0）；**有意偏离处方 (a)：只补 `parentBoxId`，不做坐标钳制**——`_clampInner` 会把手画的框外几何压成 0.02 的细条；下游 `layer2BoxToSliceRect` 已钳制到 0..1。
- SR2-11：`confirmSplitIntoImpl` 本来就是单事务——纯测试缺口，加触发器测试（`question_boxes` 上的 BEFORE INSERT）。
- SR2-25：尾部 `saveRecentTask` 包 try/catch，失败不影响成功提示与列表刷新。
- 验证：`b5_p1_256_test` 11/11；`collect_page_test` 45/45。

### A-queue — SR2-5、SR2-6、SR2-26（`B6-P1-QUEUE.md`）

- SR2-5：`_batchTagRedo` 保存后同步 `_questions`（与 `_batchAddFolder` 同款）。
- SR2-6：`_saveCurrent` 把保存后的行写回 `_queue`（根治；B5 的 `_openQueue` 一次性补丁已删，多余）。
- SR2-26：新增 `_trySaveCurrent()`（try/catch，失败提示“保存失败，请重试”并返回 false），`_goTo` / `_openQueue` / `_jumpToQuestion` / `_applyQueueSort` 都走它；**有意偏离：SR2-26 选了“拦住”而不是“放行”**——放行会立刻经 `_loadForm` / `_refresh` 用旧行重建表单，丢掉未保存的编辑，“编辑留在内存里”不成立；`_saveDraft`（不再谎报“草稿已保存”）与 `_openDetail` 也走了 `_trySaveCurrent`。
- 验证：整理页测试 38/38（30 + 9 新增，含 1 个对照）；回滚检查（去掉修复 → 8 个新测试失败）。
- 测试技巧备注：队列层 `DropdownButton` 菜单点击在测试里落不下去（OverlayEntry + PopupRoute 的测试绑定问题，疑似测试侧而非产品问题）——排序失败测试改用键盘（Tab + Enter）。
- 遗留：`_confirmCurrent` 自身的保存（`repo.save` + `syncCauseRecords` + `saveRecentTask`）仍无 try——SR2-26 没点名的第 5 处，未动。

### A-dropdown — SR2-7、SR2-34（`B6-P1-DROPDOWN.md`）

- SR2-7：`_buildMoveSelBar` 算 `effectiveTargetId`（非法 → `'__top__'`，不写回）；`_moveOneFolder` 用已有 `_folderById` 安全查找（缺失/跨学科 → 经 `_moveSelected` 汇总报“目标文件夹已经不存在了”，不再抛 `StateError`）；`_openDirectory` / `_openShelf` / `_deleteFolderConfirmed` 里把 `_moveTargetId` 重置为 `'__top__'`。
- SR2-34：`_causeFilter` / `_filterErrorType` 在 `_load` 的 `setState` 里校验，`effectiveValue` 就地兜底。
- 验证：`wrongbook_page_test` 71/71（+3）；`review_page_test` 37/37（+1）；反向对照（去掉守卫 → 4 个新测试以报告里的 DropdownButton 断言失败）。
- 遗留：`_filterExamId` 与复习页 `_subjectFilter` 没有页内删除路径（学科/试卷只能在学科管理里删，那里 State 会重建）——若将来出现新的页内删除路径，考虑补 `effectiveValue` 守卫。

### B-docs — SR2-8、SR2-9、SR2-10（`B6-P1-DOCS.md`）

- 8 处，4 个文件；同款过时措辞在 `docs/代码地图.md:477` 也一并修正。
- Grep：旧措辞残留 0。
- 遗留：历史报告（P0B2-P1-REPORT.md、B3-DOCS.md、SELF-REVIEW-DOCS.md、SELF-REVIEW-DATA.md 等）里的同款旧措辞有意不动（历史记录）；D-07 仍描述占位服务，但已标“被 D-23 取代”。

## 阶段 C/D：P2 数据层与整理 / 错题本 / 服务

### C-data — SR2-14～19 + 数据测试 SR2-58/59/65～70（`B6-P2-DATA.md`）

- SR2-14：逐列 UPDATE，不再整行 REPLACE 快照（`setReviewJoinedInto` 不再把 `review_count` 重置回旧值）。
- SR2-15：`upsertFolder` 判重 + 插入同一事务。
- SR2-16：备份校验拒绝空字符串 TEXT 主键 / 必填字符串（`settings.value` 除外）。
- SR2-17：`readZip` 拒绝重名条目（`backup.json` 重名仍允许，后者为准）。
- SR2-18：确认拆题的框回填复用保留任务的 `seenIds` 去重。
- SR2-19：恢复估算改峰值口径 `usedBytes + incomingBytes`（不再扣已替换文件）。
- 测试：`b5_p2_data_test` 36→55；`b5_p0_1_orphan_test` 3→4。
- **B5-P2-DATA.md 已纠正：SR-P2-6 的“已测”说法是假的——覆盖到 Batch 6（SR2-66）才来。**
- 偏离：`toggleFavorite` / `archive` / `save` 在共享 choke 点修，未按仓库层逐列方法做（`repository.dart` 不在本批范围）；SR2-19 峰值口径偏保守（最终体积 < 2GB 但峰值 > 2GB 的备份现在会被拒——Meng 如不同意需他定）。
- 遗留：SR2-16 对既有备份 fixture 的影响面需全量跑确认；SR2-15 并发测试依赖 sqflite 事务串行化。

### D-collect — SR2-20、21、22、23、37 + 测试 SR2-51、SR2-62（`B6-P2-COLLECT.md`）

- SR2-20：`_restoreAutoBoxForRework` 重写（按 `questionId` 定目标，贪心 IoU 匹配，题内框跟自己的框走；部分匹配加提示）。
- SR2-21：`hasManual` 只看当前页。
- SR2-22：保留任务重建时直接写 `status: boxing`（持久化信号，无 schema 改动；`_hasSplitSibling` 保留作旧 needBox 行的兜底）；**用的是方案 (a) boxing 标志，不是方案 (b)**。
- SR2-23：`allCauses` 保序去重。
- SR2-37：`_loadPageImageSize` 的 Codec 释放。
- 测试：`b5_p2_collect_test.dart` 新增 5、改 1。
- 偏离：SR2-62 在产品代码里加了 6 行 `_lastSplitStamp` 碰撞重抽（`collect_page.dart:453-457,537-542`）；B5-P2.md:27 与 B5-P2-COLLECT.md:52 的“持久化信号”已纠正为“派生信号”；B5-SUMMARY.md:23 同款措辞由协调员在收尾时改掉（见下）。
- 遗留：旧 needBox 保留行仍靠 `_hasSplitSibling`（删拆分行后警告仍会消失——存量行的一次性处理需定）；SR2-62 同毫秒场景未确定性覆盖。

### D-wrongbook — SR2-28、29、30、32、33 + 月筛选 + 测试 SR2-52/53/74/75/76（`B6-P2-WRONGBOOK.md`）

- SR2-28：搜索状态下的拖动排序拒绝（方案 a）。
- SR2-29：报告学科分布扣掉已掌握（`report_page.dart:182` 的 `_isMastered`）——Meng 已定口径 #1。
- 月筛选：错题本统一 `age < limit`（`wrongbook_page.dart:606`），文案“最近 30 天”（`wrongbook_list.dart:286`）——Meng 已定口径 #3；报告页“本月”是自然月，不动。
- SR2-30：缓存扫描递归进 cache/thumb/tmp 目录，按类计文件（探针 fixture 重算：temp=6、thumb=2、共 8 项，原为 temp=3、thumb=1、共 4 项）。
- SR2-32：拼音排序（`_subjectPinyinKey`，三级比较，空名回落 `'{'` = 排最后）。
- SR2-33：分组入口的作用域文案“学科名 · 错因”。
- 测试：wrongbook +8/改 1；review +1/改 1。
- 遗留：SR2-29 打破既有用例（`test/report_page_test.dart`“分布只按学科：本周数学 3 · 英语 2 · 政治 3”，q4 已掌握 → 英语变 1）——**协调员已修**（见“协调员收尾修复”）；`test/settings_page_test.dart` 在门禁跑之前无真实运行记录（见门禁）；三个高风险走查点（SR2-52 跨学科筛选面板、SR2-28 DragTarget 下标 6、SR2-76 Checkbox 顺序）；`_clearCache` 现在只删文件，留空缓存目录（下次扫描为 0，无害）。

### D-services — SR2-24、31、35、36、38 + 测试 SR2-13/54/55/56/63/77/78（`B6-P2-SERVICES.md`）

- 12/12 完成。
- SR2-24：只有切片来源父框（第一个 1 层框）的题内框参与竞争。
- SR2-35：方案 (a)，标签检测区包左内边距 + 间隙，× 检测区延到右内边距，chip 尺寸不变。
- SR2-36：`subjectLabelColor` 委托 `DesignTokens.subjectColor`（第三入口也雾化）——Meng 已定口径 #5 的缺口之一；`subjects_page.dart:43` 过时注释已修。
- SR2-38：只改检测路径，`minSize: false`（交路检测语义）。
- SR2-31：25° 阈值，第 13 科落在 284°，`0xFFB34CD9`，最小色相距 31.8°——Meng 已定口径 #5 的另一缺口。
- 测试：SR2-13（% 徽章）、SR2-54（2GB−1MB + 2MB PDF 拒绝）、SR2-55（字面值 `0xFF7CAAF2` + 暖红第二输入 `0xFFE68C90`）、SR2-56（第 13 科字面值 + 色相 ≥25°）、SR2-63（dpr 1.0 + 上限 2048/384）、SR2-77（0→70 连续回调）、SR2-78（ZIP64/多盘/EOCD 长度不匹配拒绝 + 合法注释可读对照）。
- 偏离：SR2-24 的测试与 SR2-78 的新分组放在 `b5_p2_services_test.dart`（原分组在工人清单外的文件里，未动）；SR2-78 的“带注释 EOCD”本身不是拒绝项（readZip 支持合法 EOCD 注释）——拒绝项是注释长度不匹配。
- 环境备注：工人自己的 7 个文件 analyze 0；测试当时因工具链缺失未跑（门禁已补跑）。

### F-docs — SR2-39～48、50；SR2-49 只写警告（`B6-P2-DOCS.md`）

- 12 项完成。
- SR2-50 差异已点名：新增 108 − 删掉的 4 个旧测试（`DashedDivider` / `InfoChip` 各 2 个，`test/widgets_forward_test.dart`，经 git diff 核实）= 净增 104；错题本组的 31 = 21+6+1+2+1。
- SR2-48 按已定口径重写。
- 协调员收尾时已处理 F-docs 的遗留（见下）。

## 补漏：SR2-27、SR2-61、SR2-64、SR2-73（`B6-P2-GAPS.md`）

- 覆盖审计发现 4 项无工人认领（SR2-57 有意缺席：Win11 手工项），第 12 名工人补做，4/4 完成。
- SR2-27：`boxesForPageImageFromImpl` 的框查询加 `orderBy: 'page ASC, id ASC'`；题 id 查询加 `orderBy: 'id ASC'`（`questions` 表无 `page` 列，SQL 上不可行，已记录）；测试 +1（`b5_p2_data_test.dart:721`）。
- SR2-61：真实仓库的首页用例（`openForTest()` + `useDatabaseForTest`，经仓库写入播种，断言 `4 道要复习` / `待解决 2 道 · 复查 2 道`）；`test/home_page_test.dart:110` 的 `pumpHome` 仓库参数放宽 `FakeRepo?` → `QuestionRepository?`。
- SR2-64：4 个断言（复查日为今天午夜与此刻，都落 `recheck` 桶，`isReviewDue` 为真）；无产品改动。
- SR2-73：`yolo_onnx_service_test.dart:473` 加 2 个并发测试；产品侧加测试可观测性（`_loadAttempts` 计数 + getter、`loadGateForTest` 屏障、`resetLoadStateForTest` 重置两者；产品门禁恒为 null）。
- **⚠️ GAPS.md 的环境结论是误判，必须纠正：工人写“本机连 flutter/dart 二进制都不在，全盘查找无 Flutter SDK”——SDK 一直在 `~/workspace/flutter-install/flutter/bin/`（3.47.9），工人只查了 PATH，没走绝对路径。其测试当时“写了、没跑”；6 个文件的括号平衡检查不能替代 analyze/test。GAPS.md 原文不动（工人报告原样保留），纠正在此。**工人跑验证时用登录 shell，或直接用绝对路径 `~/workspace/flutter-install/flutter/bin/flutter`。

## 协调员收尾修复（门禁中发现并修掉的）

### 文档同步（2026-11-15 ~10:11 UTC，直接改）

1. B5-SUMMARY.md 的“需 Meng 裁决”小节改写为“已裁决（2026-11-15，Meng‘全部同意’，第六批已落实）”（月筛选、reviewCount、三项裁决——三条都已定）。
2. B5-SUMMARY.md:23 的“持久化信号”→“派生信号（由现存同源拆分任务行派生）”。
3. CODEBUDDY.md“当前状态”更新到 2026-11-15（Batch 1–5 已推 6448c45；Batch 6 完成、在树里、未推，等 Meng 批准；本地 head 仍是 bca8586，远端 head 6448c45）。
4. 四方分工.md“眼前第一步”更新（Batch 5 已推；第二次自审 + Batch 6 完成；GPT 一次性复审做完，P0 0/P1 4，不安排第二轮；推送等 Meng 另外批准）。
5. 代码地图.md:153 的 Batch 5 测试文件清单补 `test/b5_p1_3_delete_exam_test.dart`。
6. F-docs 的两处遗留已落实：CODEBUDDY.md:43（“Batch 1/2/3/4 的改动在工作树里，未提交、未推送”）与四方分工.md:60-61（“Meng 在自审汇总后决定是否推送代码”）的过时表述已随第 3、4 条更新，不再单列。

### SR2-29 测试跟进

- `test/report_page_test.dart` 的分布用例改名“分布只按学科、扣已掌握：本周数学 3 · 英语 1 · 政治 3”（英语 2→1），另加 SR2-29 专用测试（英语只剩已掌握 q4 →“英语 · 0 道错题”，数学仍 3）。文件 analyze 0；门禁跑已验证。

### 门禁跑发现的用例问题（全部是测试侧，产品行为正确）

- **SR-P2-44（`plainText`）**：D-wrongbook 的 SR2-52 新增用例用 `find.text('函数极限')`，同时命中搜索框自己的 `EditableText`。改为 `plainText()`（只匹配 `Text`，文件已有 helper）。受影响文件 4 个串行跑：**170/170**。这也是 `test/settings_page_test.dart` 首次真实运行记录（SR2-30 缓存扫描测试通过）。
- **SR2-27 种子**：测试给 2 道题各 2 个框，违反 partial unique index（一题一 1 层框）。改 4 道不同题各 1 个框（保持倒序插入），q5 覆盖另一页。
- **SR2-61 超时**：sqflite_ffi 走 isolate，`testWidgets` 的 FakeAsync 永远收不到 isolate 端口消息，直接 await 播种会挂 10 分钟。播种 + 仓库断言移进 `tester.runAsync`（真实异步区）；`pumpHome` 加 `settle: false` 参数；首页 `_load()` 的 `Future.wait` 在 FakeAsync 下也永远完不成（加载转圈一直转，`pumpAndSettle` 超时）——改真实时间驱动（最多 30 次：`runAsync(Future.delayed(100ms))` + `pump()`，见到 '4 道要复习' 即停）；测试另有 90s 超时兜底。重跑约 1s 通过。
- **SR2-73 真机模型测试 SIGSEGV**：两次并发 `detectPage` 共享静态 `_questionSession`，并发 `runAsync` 会段错误（单次推理正常，p05 e2e 通过）。**产品加固**：`lib/services/yolo_onnx_service.dart` 里推理经静态 Future 链串行（`_detectQueue` + `_serializedDetect`）；加载共享不受影响（并发检测仍合流到同一个 `_loadFuture`，推理轮流跑）。重跑通过；缺模型测试此前已过。

### 第一次全量门禁的 9 个失败（第二次全量已清零，见下）

第一次全量（analyze 0；Linux Release 构建通过；演示库 md5 不变）：**9 失败**——`b5_p2_collect_test.dart` 4 个 + 其余文件 5 个（当时输出尾部截断，未看到身份）。收集文件的 4 个当时已定位并修掉：

- **SR2-21 + SR2-20**：`_openEditorDialog` helper 断言固定文案 '确认修框，去整理'，但 2 个 1 层框合计时文案是 '确认修框，拆成 2 个待整理任务'（`box_editor.dart:1174`，`total = _totalLayer1` 跨页合计）。helper 与 `_tapConfirm` 改 `find.textContaining('确认修框')`；SR2-21 的最终断言改为精确的 '拆成 2 个' 文案。（一次编辑先误中同名单框 '对照' 测试，已纠正：那处保留 '去整理'，SR2-21 保留 '拆成 2 个'。）
- **SR2-23（过时 Batch 5 测试）**：该测试期望第 2 个 1 层框下的题内框按该框换算——**已被 SR2-24 取代**，其处方（只有切片来源 = 第一个 1 层框的题内框参与竞争；切片只从第一个框切）由 D-services 落地，SR2-24 测试已在 `b5_p2_services_test.dart:731`。过时测试已从 `b5_p2_collect_test.dart` 删除，留注释指向 SR2-24 分组；同组 `parentBoxId` 为空的兜底测试仍通过。
- **SR2-62（同一用例内两次确认）**：临时调试打印定位（已删干净，文件内无 `TMP` 残留）：第二次确认的轮询在第一次确认的**陈旧 '已生成' snackbar**上立刻跳出——snackbar 在 `tester.runAsync`（真实区）里弹出，其 4s 计时器是真实区 Timer，假时间 `pump(Duration(seconds: 5))` 推不动；循环在 `_confirmSplit` 还没跑完就返回，`repo2.confirmedQuestions` 仍是 null。（对话框本身已正常弹出——`confirmBtn=false`——`_confirmSplit` 还在飞。）修复：两次确认之间 `ScaffoldMessengerState.clearSnackBars()` + `pumpAndSettle()`。
- **SR2-22（UniqueKey 修复后才破，原先通过）**：`_pumpCollect` 加 `key: UniqueKey()`（重 pump 时挂新 State、按给定仓库重载——`CollectPage` 只在 `initState` 加载，无 `didUpdateWidget`，换假仓库重 pump 会复用旧 `_tasks`）。重载后 SR2-22 测试期望破了：第 1 页的覆盖也随任务删了（其题按删除语义随任务走），未框 = [1, 2] = 全部页 → `_noBoxWarningText` 返回 '这份文件还有 2 页没有框'（不是 '还有 1 页没有框：第 2 页'）。期望已更新并加注释；SR2-22 的点（警告靠保留任务自己的 `boxing` 状态存活，不靠派生的 `_hasSplitSibling`）仍然成立。UniqueKey 改动只是测试 helper；产品从不在已挂载页上换仓库，故未加 `didUpdateWidget`。
- 收集文件修复后：**31/31 通过**。演示库 md5 不变。

### 第二次全量门禁的 5 个失败（第三次全量前已修掉）

第二次全量：**847 通过、5 失败**（演示库 md5 不变）。5 个全是旧用例钉住 Batch 6 已定行为的测试侧问题，产品行为正确：

- **深色雾化 4 个**：`b5_p2_services_test` 的 SR-P2-66（字面值 `0xFF7CAAF2`）与 SR2-36、`s8_chip_label_test` 的两处（“新学科：显示‘化学’+存色紫”与“subjectLabelColor：新学科传存色亮/深都直接用存色”）——旧用例断言“深色直接返回存色”，与已定的 SR2-36（`subjectLabelColor` 第三入口也雾化）冲突。根因分两层：(1) D-services 写 SR2-36 测试时用的字面值本身是对的，但 `Color.lerp` 产出带小数通道的 Color（如蓝通道 241.5），与字面量 `0xFF7CAAF2`（蓝 242）按 `Color==` 不等——探针实测三组雾化色的 `toARGB32()`：`0xFF2E7CF6`→`0xFF7CAAF2`、`0xFFEF4444`→`0xFFE68C90`、`0xFF7C5CFC`→`0xFFA799F5`，与注释字面值一致；(2) s8 的两处按亮/深拆期望：亮色存色、深色 `0xFFA799F5`，用例改名以反映新行为。修复：雾化值断言改 `.toARGB32()` 对字面值（保留 SR2-55“字面值钉雾化本身”的意图；8 位色值才是对外可见的约定），预设三科的调色板常量仍按 `Color==` 断言。
- **SR2-36 亮色分支又一层**：第二次 pump（只给 `theme: AppTheme.light()`，无 themeMode）后只 `pump()` 一帧，`Theme.of` 仍是旧的深色主题——`AnimatedTheme` 默认 200ms 动画没走完。探针证实：第二次 pump 里 `Theme.brightness` 仍是 dark（平台亮度一直是 light）。修复：该处改 `pumpAndSettle()`，并在用例里留注释说明。
- **P1-2（`collect_page_test.dart:1145`）**：旧 Batch 3 用例期望保留任务状态 `needBox`，SR2-22 已改为 `boxing`（代码注释明示意图：保留任务只可能由编辑器确认产生，必定打开过，直接写 boxing；行上按“修框中”显示）。修复：两处状态期望改 `boxing`；筛选点击由 `collect-filter-needBox` 改 `collect-filter-boxing`（筛选是精确状态匹配，boxing 行不再出现在待框选筛选里）；重进修框的按钮由 '修框' 改 '继续修框'（boxing 行的按钮文案）；注释同步。
- 三个受影响文件修复后重跑：**81/81 通过**（`b5_p2_services_test` + `s8_chip_label_test` + `collect_page_test`）。演示库 md5 不变。

## GPT 一次性复审分流结论（2026-11-15 ~09:50，主会话转达）

- 思考模式对话：**P0 0 项、P1 4 项**。逐项对照第二次自审，**全部已有、无新增**：P1-1 = SR2-3（详情页重框删唯一切片）、P1-2 = SR2-4（确认拆题丢无父框独立题内框）、P1-3 = SR2-1 的图片解码失败子型、P1-4 = SR2-2（`_failAndClean` 自身写库失败逃出 `enqueue`）。
- Batch 6 范围不变，按原计划修；GPT 声明复审结束，**不安排第二轮**。
- 非思考模式对话也回了一份（P0 0、P1 1，只 SR2-3），以思考模式那份为准。
- 本批已把 GPT 的 4 项全部修掉（SR2-1/2/3/4，见阶段 A）。

## 口径决定落实（Meng 2026-11-15“全部同意”）

1. **SR2-29**：报告学科分布扣已掌握（D-wrongbook）。
2. **SR2-40**：“不设序号”指紧凑列表行不设行号，大卡片蓝色序号圆盘保留（F-docs，边界 §4.4）。
3. **月筛选**：错题本 `age <= 30` → `age < 30`，文案“最近 30 天”；报告页“本月”自然月不动（D-wrongbook）。
4. **reviewCount**：不显示，字段留作内部计数（无代码改动，口径记录）。
5. **三项协调员裁决都成立**：SR-P2-66 雾化（45% 混 `#DCE3EC`）成立、缺口 SR2-36 已补；SR-P2-51 12 色 + 金角成立、缺口 SR2-31 已按 25° 阈值重算；SR-P2-52/55 直接通过。SR-P2-52/55 不改代码。

## 覆盖说明

- 第二次自审 78 项中，**77 项**有 B6 报告覆盖；唯一缺席的是 **SR2-57**，有意不做：Windows 文件锁分支，Linux 测不了，只记入复核清单（见下），不改代码。
- SR2-49：SELF-REVIEW.md 已冻结，不改；在此警告——**不要采信 SELF-REVIEW.md 里 SR-P2-81 的证据句“reviewCount 仍保留显示”，它是错的**（reviewCount 无任何页面渲染；详情页“解决次数”显示的是 `_history.length`）。

## Win11 真机复核清单（Linux 无法验证，待 Meng / CodeBuddy）

- **SR2-57**：P2-11 的 Windows 文件锁分支（Linux 测不了）。
- SR-P0-2 的真机列表行为（第二次自审已注：需真机复核）。
- 其余沿用 2026-11-14 09:15 的验收清单：`flutter build windows`（libpdfium 打包 + onnxruntime.dll + VS C++ 工具链）、字体/DPI/窗口尺寸、SQLite 原生资源、真实文件全流程、详情页“重新框选”端到端点击、拖拽导入、错题本分页。
- 测试夹具 zip 链接 **2026-11-16T00:41:08Z 过期**（本地副本 `~/workspace/qm2-test-fixtures.zip` 可重传）。

## 遗留（未修 / 需另定）

- `_confirmCurrent` 自身的保存无 try（SR2-26 没点名的第 5 处）。
- SR2-3 的重命名失败分支未测（需文件系统故障注入）；进程中途被杀留 `.tmp` 孤儿文件（孤儿扫描覆盖）。
- 失败行本身写不进库时，DB 任务卡在 `importing`（处方内降级，已钉测试）。
- SR2-12 同毫秒确定性覆盖需可注入时钟重构（本批范围外）。
- 旧 needBox 保留行仍靠 `_hasSplitSibling`（删拆分行后警告仍会消失——存量行的一次性处理需定）。
- SR2-19 峰值口径偏保守（最终体积 < 2GB 但峰值 > 2GB 的备份现在会被拒——Meng 如不同意需他定）。
- `_clearCache` 只删文件、留空缓存目录（下次扫描为 0，无害）。
- `toggleFavorite` / `archive` / `save` 在共享 choke 点修，未按仓库层逐列方法做（如要，另立项）。
- SR2-62 同毫秒场景未确定性覆盖。
- SR2-15 并发测试依赖 sqflite 事务串行化；SR2-16 对既有备份 fixture 的影响面待全量确认。
- 历史报告里的过时措辞有意不动（历史记录）。
- `double` 封面折角：Meng 自己与 CodeBuddy 协调，Muse 不做（原决定不变）。
- 检测质量（密集排版重叠框）不在本批范围；P3(b) 孤儿目标迁移（需合并语义）仍待定。

## 工具链插曲（本批内两次丢失，均已恢复）

- ~09:55 UTC：VM 疑似被换，全量跑在 ~204s 被 SIGTERM；随后 clang/ninja 全失，`flutter test` 报 “No compiler configured on host 'linux_x64'”。主会话跑 `restore-linux-toolchain.sh` 恢复（~10:12 UTC 验证：clang 18.1.3、ninja 1.11.1、GTK 3.24.41、ImageMagick、xdotool）。
- PATH 误判：B6-P2-GAPS.md 称“全盘无 Flutter SDK”——SDK 一直在 `~/workspace/flutter-install/flutter/bin/`（3.47.9），只是 VM 换后 `~/.profile` 没了、`.bashrc` 是新的空文件。主会话已修（`.bashrc` 加 export，`.profile` 会 source `.bashrc`；登录 shell 下 `which flutter/dart` 都通）。
- 教训（已多次验证）：测试串行 `--concurrency=1`（防 hooks_runner 锁争抢）；`testWidgets` 里不用异步文件 IO；sqflite_ffi 的 isolate 调用在 FakeAsync 下永远不回——播种走 `tester.runAsync`，加载用真实时间驱动，禁用 `pumpAndSettle` 等加载转圈；`runAsync` 里弹出的 SnackBar 用真实区计时器，假时间推不动——用 `ScaffoldMessengerState.clearSnackBars()` 清掉；无 key 的 widget 重 pump 会复用 State——换仓库的测试 helper 要用 `UniqueKey`；`find.text()` 也会命中搜索框的 `EditableText`——列表行文本用 `plainText()`；换主题后要等 `AnimatedTheme` 走完（`pumpAndSettle`），只 `pump()` 一帧会读到旧主题；`Color.lerp` 产出带小数通道，雾化值断言用 `.toARGB32()` 对字面值。
