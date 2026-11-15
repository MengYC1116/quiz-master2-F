# Batch 5 第五阶段 P2：收集 / 整理 / 详情页 — 工人报告

- 工作树 `~/workspace/quiz-master2-UI`，分支 `ui-replication`；未 commit、未 push，未动 git 历史。
- 范围：`lib/modules/collect/*`、`lib/modules/organize/*`、`lib/modules/detail/*`、`lib/models/models.dart`（仅加 `newEntityId`）、`lib/widgets/widgets.dart`（仅叠加层 / QuestionSlice 区域）。
- 原任务 18 项（SR-P2-18、19、20、21、23、24、25、26、27、28、29、30、31、32、33、34、35；SR-P2-22 不属原任务）+ 补充转交 4 项（SR-P2-3、SR-P2-22 剩余部分、SR-P2-36、P1-2 旧测试同步）。
- 结论：22 项全部完成；新回归测试 26 项全部通过；针对性回归 `collect_page_test` 43、`organize_page_test` 29、`detail_page_test` 27（合计 99）全部通过；`flutter analyze` 我负责的文件 0 问题（全树仅剩另一工人 services 测试文件的 2 个 warning，见 §6）。

## 1. 原 18 项逐项结果

| 项 | 结果 |
|---|---|
| SR-P2-18 切页自动检测只认 1 层框 | 无代码改动——门控早已由 P1-5/P1-6 修好（`initState` 的 `hasDraftOnPage` 与 `_autoDetectIfEmpty` 均认 1 层 + 内框 + 独立框）。只补回归测试：独立题内框的页切走再回来不重检测。 |
| SR-P2-19 “恢复自动框”手动判断只认 1 层框 | `box_editor.dart` `_restoreAutoBoxes`：`hasManual` 增加 `_inners` 与 `_standaloneInner` 中 `origin == 'manual'` 的检查。纯 YOLO 页仍直接替换、不弹确认。 |
| SR-P2-20 重框“恢复自动框”只换 1 层框 | `_restoreAutoBoxForRework`：目标题内框按新旧 1 层框相对位置等比跟随，再 `_clampInner` 钳进新框；旧框无面积时只钳制。 |
| SR-P2-21 内框模式鼠标左键点空白不退出 | 祖先画布 `Listener.onPointerDown`：鼠标主按键 + 内框模式 + 未点中可交互元素 → `_exitInnerMode()`；点框/手柄仍拖动。 |
| SR-P2-23 叠加层换算取第一个 1 层框 | `widgets.dart` `realRegionRects`：每个 2 层框按自身 `parentBoxId` 找父框换算；`parentBoxId` 为空（老数据）时回退到第一个 1 层框。 |
| SR-P2-24 同区域多框取第一个无确定性优先级 | 同函数：确定性优先级改为面积最大者胜、面积相等取列表第一个（旧 b3 测试“同区域多个框取第一个”仍通过：等面积）。`boxesForPageImageFromImpl`（`lib/data/db_collect.dart:205-222`）的 `ORDER BY page ASC, id ASC` 在数据层文件里，见 §7 转交。 |
| SR-P2-25 红色无框警告收窄 | `collect_page.dart`：`_load` 统计 `_hasAnyDraftBox`（任意层、任意页）；行警告仅当 `status == boxing` 或有任意草稿框。另补信号（见 §2）：P1-2 保留任务按同 id 重建回 `needBox`、未框页可能无草稿——有同源拆分任务（`_hasSplitSibling`）即视为打开过，照样警告。 |
| SR-P2-26 详情页新建文件夹无真正取消路径 | `_newFolder` 的 `SimpleDialog` 增加“取消”项；返回值 `'top'`=顶层、`''`=点取消、`null`=点框外关闭，后两者都不建。 |
| SR-P2-27 自定义错因与固定枚举同名 | 整理页 `_addCustomType`：输入固定名直接选中固定项 + 提示，不进自定义集；`customOptions` 过滤固定名；`_loadForm` 与 `_formQuestion` 合并旧数据里的同名自定义。详情页 `_newCustomErrorType` 同理；`_beginEdit` 读入合并、`_saveEdit` 保存前合并（旧代码在 `customNew` 里静默过滤丢错因）。 |
| SR-P2-28 毫秒时间戳 id 连点覆盖 | 新增 `models.dart` `newEntityId(prefix)`（`<prefix>-<ms>-<8 hex>`，`Random.secure()`，与 `AppDatabase.newBoxId` 同方案）。替换：收集页 `_failTask`、整理页 `_submitNewFolder`/`_submitNewExam`/`_submitBatchFolder`、详情页 `_newFolder`/`_newKnowledgePoint`/`_newExam`。收集页 `:501` 的 `'import-$ts-$p-$i'` / `'task-$ts-$p-$i'` 未动（页 + 序号已能区分）。 |
| SR-P2-29 整理页修框切片整题卡未传学科 | `_slicesSection` 整题卡 `QuestionSlice` 补传 `subject: _subjectOf(q.subjectId)`（`_paperImage` 处早已传）。附带修：`_missingImagePlaceholder` 包 `FittedBox(scaleDown)`——缺图占位 Column 自然高约 100px，在 66px 切片卡里溢出 35px（生产环境已存在的溢出）；空间足时原样显示。 |
| SR-P2-30 `_donePages` 只是装饰态 | 行为不变，只改文案：按钮“标记本页修完”/“已标记修完（点击取消）”，说明改为“打勾只是本次打开的标记：不保存草稿、也不参与确认，切页或取消后标记消失”。 |
| SR-P2-31 切页与取消保存草稿无 try | `_switchPage` 的 `_saveDraftIfNeeded()` 包 try/catch：失败弹“草稿保存失败：…，框还在，切回来再试一次”，仍切页；取消按钮同样 try/catch，失败提示后仍退出（`barrierDismissible=false` 否则会困住用户）。 |
| SR-P2-32 `firstWhere` 无 `orElse` 硬查 | `box_editor.dart`：新增 `_layer1ById(id)` 可空查找；替换 6 处无 `orElse` 的硬查——`_enterInnerMode`（外框缺失直接返回）、`_replaceBox` 内框分支（外框缺失→页级钳制、`_inners` 缺失→不做事）、`_confirmPendingType` 内框分支（外框缺失→存为独立框）、`_onDrawStart`/`_onDrawUpdate`/`_onDrawEnd`（外框缺失→退出内框模式返回）。注：这些路径在 UI 上不可达（删框会清内框模式），守卫是防御性的，见 §6。 |
| SR-P2-33 `CollectStatus.done` 无赋值处 | 核实：生产代码无 `done` 写入（仅 `lib/data/db_codec.dart:181` 把库里旧字符串解析回来）。`done` 分支保留作防御，并在 `_load` 的 `splitPagesBySource` 处加了说明注释。无行为可测。 |
| SR-P2-34 死代码 `DashedDivider` 与 `InfoChip` | 已删（`lib/` 内零调用点）。`test/widgets_forward_test.dart` 里对应的 4 个测试已删（EmptyState 测试保留）。`lib/widgets/uikit.dart` 约 524/558/1630 行的注释仍提到它们，见 §7 转交（uikit.dart 不属我范围，未动）。 |
| SR-P2-35 `_subjectInitial` 与 `_dateText` 重复实现 | 抽为文件级 `_subjectInitial` 与 `_dateText`（`yyyy-MM-dd` 零补齐）；删 `_OrganizePageState` 与 `_QueuePopupState` 里的重复份；队列弹窗详情行日期改用补零格式（与已定决定 #11 一致）。顺手修了编辑引入的 2 个 `prefer_collection_literals` info。 |

## 2. 补充转交 4 项结果

### SR-P2-3 详情页重框孤儿切片
`question_detail_page.dart` `_reworkBoxes`：`replaceQuestionBoxesAndSlice` 调用包进 try/catch；事务失败时删刚写的切片文件（`sliceAbs`），再按现有失败路径提示“重新框选失败：保存失败，请重试”并返回。回归测试 1 项（事务桩抛错 → 切片被删、提示失败、框与题不动）。

### SR-P2-22 收集页确认失败孤儿文件
`collect_page.dart` `_confirmSplit`：
- 循环内记清单 `writtenRels`：旋转烘焙图只记 `rotation != 0` 时新建的 `bakedRel`（`rotation == 0` 时 `bakedRel` 就是原页图，不记、不删）；切片每写一个记一个；先记后写（写一半的残文件也清掉）。
- 裁剪/写盘失败的 `catch` 里按清单删文件，再提示 + `_load()`。
- `confirmSplit` 事务调用同样包 try/catch：失败时按同一清单删文件，提示“拆题失败：保存失败（…），请重试”，`_load()` 后返回；任务本身不动，可重试。
- 任务重建两步写的问题已在 P1-2 由数据层解决，未再改。
- 回归测试 2 项：第 2 页裁剪失败（第 2 页图损坏字节）与事务失败（桩抛错）——两种失败下第 1 页已写的切片与烘焙图都被清掉，原任务页图完好，任务留在待框选可重试。

### SR-P2-36 组织/详情新建文件夹预检
数据层已在 `upsertFolder` 加整科同名把关（命中抛 `StateError`，文案含“已经有了”）。三处调用方补齐：
- 整理页 `_submitNewFolder`、`_submitBatchFolder`：调 `repo.folderNameExistsInSubject(subjectId, name)`（新建不传 `excludeId`），命中提示“已经有了”并中止；旧的只查顶层同名本地检查被整科预检取代；`saveFolder` 外再包一层 `StateError` 捕获作竞态兜底。
- 详情页 `_newFolder`：选好父级后、保存前同样预检 + `StateError` 捕获。
- 回归测试 2 项：整理页顶层已有同名拦、跨层同名（仅子文件夹同名时建同名顶层）也拦；详情页已有同名、选顶层也拦。
- 为让现有 widget 测试走内存版预检，给 `FakeOrganizeRepo`（`organize_page_test.dart`）、`FakeDetailRepo`（`detail_page_test.dart`）与我文件里的两个 Fake 补了 `folderNameExistsInSubject` 覆盖（与 `upsertFolder` 把关同语义）。

### P1-2 旧测试同步（SR-P2-25 收窄的后续）
`test/collect_page_test.dart` 两项旧测试原来按“从未打开也警告”断言：
- “确认前报未框页数，确认后只拆有框页、未框页留任务可继续修框”：**未改测试**。原因是保留任务确实打开过——按 Meng 已定决定它应当继续警告。实现上补了一个持久化信号：`_load` 增加 `_hasSplitSibling`——有同源拆分任务（待整理/已整理）的 needBox 任务一定打开并确认过（拆分任务只可能由编辑器确认产生；`sourcePath` 含原任务 id，重导入不串）。该测试现原样通过。
- “无框警告：单张图没框 / 多页部分没框出警告，全框了不出”：**已按新行为更新**（改名“无框警告：有草稿的任务出警告，从未打开的单张图不出，全框了不出”）：从未打开、无草稿的单张图任务不再警告（`findsNothing`）；有草稿的多页卷仍警告未框页；红色（`errInk`）校验改到多页卷警告文本上。

## 3. 改动文件

生产代码：
- `lib/models/models.dart`：新增 `newEntityId(prefix)`（+ `dart:math` 导入）。
- `lib/modules/collect/box_editor.dart`：SR-P2-19、20、21、30、31、32。
- `lib/modules/collect/collect_page.dart`：SR-P2-25（含 `_hasSplitSibling` 补信号）、SR-P2-28、SR-P2-33（注释）、SR-P2-22（`writtenRels` 清单 + 两处失败清理 + `_deleteWrittenFiles`）。
- `lib/modules/organize/organize_page.dart`：SR-P2-27、28、29、35、36。
- `lib/modules/detail/question_detail_page.dart`：SR-P2-26、27、28、SR-P2-3、SR-P2-36。
- `lib/widgets/widgets.dart`（仅叠加层 / QuestionSlice 区域）：SR-P2-23、24、34、SR-P2-29 附带 `_missingImagePlaceholder` 的 `FittedBox`。

测试：
- `test/b5_p2_collect_test.dart`（新建）：26 项回归，见 §4。
- `test/collect_page_test.dart`：P1-2 组第二项按 SR-P2-25 新行为更新（见 §2）。
- `test/organize_page_test.dart`、`test/detail_page_test.dart`：各补 `folderNameExistsInSubject` 的 Fake 覆盖（SR-P2-36）。

## 4. 测试

新文件 `test/b5_p2_collect_test.dart`，**26/26 通过**（最后一次全量跑 2026-11-15）：
- SR-P2-28 `newEntityId` 唯一性/格式（2000 次快速调用）；SR-P2-23/24 `realRegionRects`（按父框换算、无父回退、面积最大优先、等面积取第一个）；SR-P2-18（独立题内框页不重检测）；SR-P2-19（手动独立框弹确认，取消保留、替换覆盖；纯 YOLO 对照不弹）；SR-P2-20（重框内框跟随 + 钳制）；SR-P2-21（鼠标左键点空白退出内框模式）；SR-P2-30（新文案 + 切换）；SR-P2-31（切页/取消保存抛错提示且不困住）；SR-P2-32 相邻可达路径（内框模式删外框后继续画框不崩）；SR-P2-25（三任务对照）；SR-P2-26（取消/框外关闭/顶层三路径）；SR-P2-27 详情 + 整理（同名合并）；SR-P2-29（新学科缺图占位）；SR-P2-35（队列弹窗日期补零）；SR-P2-3（事务失败删新切片）；SR-P2-22（裁剪失败与事务失败两种清理）；SR-P2-36 整理 + 详情（顶层同名与跨层同名预检）。

针对性回归（lib 定稿后重跑）：
- `test/collect_page_test.dart`：43/43 通过。
- `test/organize_page_test.dart`：29/29 通过。
- `test/detail_page_test.dart`：27/27 通过。
- 三文件同跑一次：99/99 通过。
- `test/b5_p2_collect_test.dart` 全量：26/26 通过。

`flutter analyze`：我负责的文件 0 问题。全树仅剩 2 个 warning，都在 `test/b5_p2_services_test.dart:274,281`（另一工人文件的 `invalid_null_aware_operator`，未动）。

测试写法注意（已写入测试文件注释，后人参考）：
- **testWidgets 体是 FakeAsync 区**：体内直接 `await` 异步文件 IO（`create`/`copy`/`writeAsBytes`）会永远挂起——完成事件等不到，连 `print`/`stdout` 都出不来。文件准备必须用同步 IO（`createSync`/`copySync`/`writeAsBytesSync`），或包进 `tester.runAsync`，或放 `setUpAll`。本次 SR-P2-3/SR-P2-22 曾因此挂起数小时，定位过程见 §6。
- `_confirmSplit` 的图片 IO（旋转烘焙 + 裁剪）偏慢：测试里用轮询等失败提示条出现（最多 8 秒，找到即停），不要定死循环次数——太短流程没跑完，太长提示条 4 秒过期。

## 5. 逐项之外的说明

- SR-P2-32 的硬查路径在 UI 上不可达（删框会清内框模式），守卫是防御性的；回归只测相邻可达路径。
- SR-P2-33 与 SR-P2-34 无行为可测（死分支保留作防御、死代码删除），报告里写明原因，未编造测试。
- `collect_page.dart:501` 的 `'import-$ts-$p-$i'` / `'task-$ts-$p-$i'` 未动（页 + 序号已能区分）。
- SR-P2-3 的取舍（按转交说明执行）：旧切片在事务前已被新切片覆盖；事务失败时按说明删新切片文件，题会暂时无切片、需再次重框才能恢复（切片可由页图随时重裁，未丢数据）。如需“失败恢复旧切片字节”，可改为写盘前先读旧字节、失败时写回——协调员定夺。

## 6. 环境问题（本次遇到的，需协调员知晓）

- **VM 重启丢工具链**：任务中途 VM 重启一次，`/usr/bin/clang` 丢失导致 `flutter test` 报 `Building native assets failed`。恢复脚本 `docs/ui-replication/restore-linux-toolchain.sh` 两次在下载 `Packages.gz` 大索引时断连（约 14MB 处 `IncompleteRead`，curl 断点续传也失败，服务器不支持 Range）。最终发现 clang 二进制其实还在、缺的是动态链接缓存：`ldconfig` 后 `clang --version` 恢复正常，`which clang/clang++/ninja` 全有。注意：`/tmp` 里有另一工人留下的 `restore-toolchain-patched.sh` / `restore-toolchain-aliyun.sh`（未动）。
- **/tmp 满**：512M tmpfs 曾到 100%，一次测试编译报 `No space left on device`。已清我自己的残缺下载与残留进程；`/tmp/flutter_tools.*` 与各工人测试临时目录是大头，并行跑测试时需留意。
- **另一工人进程卡住（非我启动，未动）**：PID 11046 的 `flutter test`（uikit 等 7 个文件）自 18:21 起卡住 30 分钟以上、CPU 仅 2 秒，持有 `.dart_tool/hooks_runner/*/​.lock`（pdfium_dart + sqlite3 四把锁），其前端编译器 11105 早在 18:21 编译完 output.dill 却未退出、未起 tester。该进程会阻塞其他运行的 hook 构建（需等锁）。建议协调员确认后处理——我按规则只停自己启动的进程。
- **FakeAsync 文件 IO 挂起（已定位，见 §4）**：testWidgets 体内异步文件 IO 永远等不到完成事件，表现为测试 0 CPU 无限挂起、连超时外的 `print` 都出不来；排查时曾误以为是详情页/图片/工具链问题。已在测试文件注释里写明，供其他工人参考。

## 7. 遗留与需转交

1. **转交数据层工人**：`boxesForPageImageFromImpl`（`lib/data/db_collect.dart:205-222`）加 `ORDER BY page ASC, id ASC`（SR-P2-24 的 a 方案；b 方案——`realRegionRects` 内面积最大优先——已做）。
2. **转交 widgets/uikit 工人**：`lib/widgets/uikit.dart` 约 524、558、1630 行的注释仍引用已删除的 `DashedDivider`/`InfoChip`，需清掉过期注释。
3. **遗留（未修）**：`QuestionSlice.build` 的 `failed` 分支占位与 `_missingImagePlaceholder` 是同一 Column，但未包 `FittedBox.scaleDown`——目前只在 480px 大图处渲染，无溢出；若将来在窄卡片里复用，有同样溢出风险。
4. **遗留（已说明）**：SR-P2-32 守卫无 UI 可达触发；SR-P2-18 门控早已修好；`CollectStatus.done` 分支为防御保留。
5. **工具链/锁**：见 §6——另一工人卡住的进程（PID 11046）与 hook 锁需协调员处理；`ldconfig` 修复是一次性的，VM 再重启可能重现。
