# B3 P1-2 多页 PDF 未框页不丢 / _restoreAutoBoxes / _importPdf 兜底

工人：b3-collect。分支 ui-replication，未提交、无 commit/push/reset/checkout。
只改：`lib/modules/collect/collect_page.dart`、`lib/services/import_service.dart`、
`test/collect_page_test.dart`、`test/pdf_collect_page_test.dart`；
新增：`test/import_service_pdf_fallback_test.dart`。
没碰：`lib/data/database.dart`、`assets/models/`、`test/fixtures/`；
树上第二批未提交改动原样保留。

## 1. P1-2 多页 PDF 未框页不丢（collect_page.dart）

### 确认前提示（`_confirmSplit` L424 起）
- 未框页 = `1..pageCount` 里没有 1 层框、且未被拆过的页（L428-450）。
- 有未框页时弹 `AlertDialog`（L456-470）：标题「还有 N 页没有框」，
  内容写明未框页码（超过 5 页只列前 5 页加“等”，`_pageListText` L645）、
  有框页数、拆题数、未框页会留在任务里；按钮「取消」「确认拆题」。
  点取消：什么都不拆，任务留修框中（`_load` 后返回）。
- 文案原文（L459）：「第 2、3 页还没有框。确认后，有框的 1 页先拆成 1 道题
  去整理，没框的 2 页会留在这个任务里，之后点「修框」继续框。」
  （数字随实际情况变）

### 保留任务的具体行为
- 只拆有框页；`confirmSplit`（database.dart 的四步同事务，未改）照常删原任务后，
  `_confirmSplit` 在 L576-620 按同 id 重建保留任务：状态回 `needBox`、
  progress 100、pageCount 不变、page = 首个未框页、createdAt / sourcePath
  原样保留、pageRotations 只保留未框页的；随后 `saveDraftBoxes` 写回未框页的
  草稿（本就没有 1 层框，只剩独立题内框）与旋转角。
- 同 id 是关键：页图目录 `imports/<id>/` 不变，页图不丢；任务回到「待框选」，
  点「修框」从首个未框页继续。
- 成功提示：有保留时「已生成 X 道题去整理，还有 N 页没框留在任务里」，
  无保留时保持原「已生成 X 道题，去整理吧」。
- 防重复拆（L428，`_splitPagesFor` L629-640）：保留任务重进再确认时，
  同 sourcePath 的拆分任务（待整理/已整理）所在页视为已拆页，跳过不切、
  不计入总数；若有效框数为 0 且确实跳过了已拆页的框，提示
  「这些页已经拆成题了，不用再拆」。sourcePath 含原任务 id
  （`imports/<id>/…`），重导入同一份文件不串。判断依据是拆分任务行
  一直留在 pendingOrganize（代码里没有任何地方把拆分任务置 done，
  `CollectStatus.done` 无赋值处），整理后也不删行，所以该信号在整理
  前后都有效。

### 红色警告
- 位置：`_taskRow`（L1124-1136），在任务名/状态行下方、导入进度条/失败
  原因上方；只对 needBox/boxing 状态的行生效，与当前筛选无关
  （「全部」下也显示）。
- 行与页的对应：一个任务一行，一行管 pageCount 张图；未框页是 `_load`
  （L107-150）按草稿框逐页算的：取 `boxesForTask` 的 1 层框所在页，
  再排除已拆页（同 sourcePath 的拆分任务所在页，`splitPagesBySource`
  L115-123）。`_load` 每读一次列表就重算一次；草稿读不到时该任务不
  出警告，列表不受影响。
- 文案（`_noBoxWarningText` L652-657）：单页「这张图还没有框」；多页
  部分未框「还有 N 页没有框：第 X、Y 页」（超 5 页只列前 5 页加“等”）；
  多页全未框「这份文件还有 N 页没有框」。颜色 `palette.errInk`（红），
  字号 bodySmall。
- 注意（实测行为）：刚导入、还没打开过修框的任务也没有草稿框，所以同样
  会显示红色警告（例如单张图新导入即显示「这张图还没有框」）。这是按
  字面规则（有未框页即警告）实现的；如需只在“部分框过/打开过”时警告，
  需协调员/Meng 再定。

## 2. `_restoreAutoBoxes` 的 hasManual（collect_page.dart L1821）

- 由 `_boxes.any((b) => b.origin == 'manual') || _boxes.isNotEmpty`
  （恒为真）改为只认 `_boxes.any((b) => b.origin == 'manual')`。
  只有 YOLO 框（origin `'yolo'`）时不再弹「用自动框替换当前页的手动框？」
  确认，直接重检替换；有手动框时仍先弹确认。

## 3. `_importPdf` 兜底 catch（import_service.dart）

- `_importPdf`：读页数 try（L337-348）与整本渲染 try（L381-390）各加
  `catch (e)` 兜底，走 `_failAndClean`（失败任务 + 删半写目录）。
  文案：读页数阶段「导入失败：这个 PDF 没导进去（$e）」；渲染阶段
  「导入失败：渲染这份 PDF 时出了问题（$e）」。原有
  `PdfEncryptedException` / `PdfCorruptException` 分支不动。
- 测试用注入的假引擎抛 `FileSystemException` 模拟磁盘满，未真写满磁盘。

## 测试

### 新增/改动
- `test/collect_page_test.dart`：
  - `_SelectiveYolo`（L77）：只在第 1 页返回 1 个题级框、其余页空框；
    origin 可指定。
  - `_seedPdfPageImages`（L114）：同步 IO 在临时数据目录种每页页图
    （见“踩坑”）。
  - `tapDialogConfirmAndWait`（L126）：点「确认拆题」并等真实 IO。
  - group `P1-2 多页 PDF 未框页不丢`（L1036）：3 个用例——①确认前报数→
    只拆有框页→保留任务回待框选→列表红警告→重进从第 2 页修→切回已拆
    第 1 页再确认不重复拆；②对话框点取消什么都不拆；③无框警告三种情形
    （单张没框/多页部分没框/全框了不出）+ 红色 errInk 断言。
  - group `恢复自动框 hasManual`（L1181）：2 个用例——只有 YOLO 框不弹
    确认；有手动框先弹确认，点取消保留原框（「取消」用
    `find.descendant` 限定在 `AlertDialog` 内，编辑器自身也有「取消」，
    直接 `find.text` 会歧义）。
- `test/pdf_collect_page_test.dart`（L180-203）：既有用例在编辑器确认后
  等「确认拆题」对话框出现、断言「还有 1 页没有框」、点确认拆题再轮询
  `savedQuestions`（该用例原本会卡在对话框处等满 30 秒后失败）。
- `test/import_service_pdf_fallback_test.dart`（新增，L71-120）：2 个用例——
  读页数时 `FileSystemException` / 渲染中途 `FileSystemException`，
  enqueue 不抛、任务 failed、半写目录已删；内存库 + 临时数据目录。

### 结果（均设 `TMPDIR=$HOME/workspace/.tmp-b3-collect`，LD_LIBRARY_PATH 含 onnxruntime-1.4.1）
- `test/collect_page_test.dart` 全文件：42/42 通过（约 49 秒）。
- P1-2 组：3/3 通过；`_SelectiveYolo` 清理后复跑 3/3 通过。
- hasManual 组：2/2 通过。
- `test/pdf_collect_page_test.dart`：1/1 通过。
- `test/import_service_pdf_fallback_test.dart`：2/2 通过。
- `test/pdf_render_service_test.dart`：13/13 通过。
- `flutter analyze`（5 个改动文件）：No issues found。
- 全量测试未跑（协调员最后统一跑）。

## 踩坑 / 过程记录
- fake-async 挂死：`_seedPdfPageImages` 最初用 await 的异步文件 IO 写在
  testWidgets 体里，fake-async zone 里真实 IO 的 Future 永不完成，用例
  10 分钟超时且无任何进度；改为同步 IO（createSync/copySync）后 12 秒
  跑完。教训与协调员补充一致：testWidgets 体内真实 IO 须同步或放 runAsync。
- 并发与 /tmp：多工人同时跑 flutter test 时编译极慢（单个用例编译曾花
  约 6 分钟）；本次收尾测试改用 `TMPDIR=$HOME/workspace/.tmp-b3-collect`
  （用完已删除）；/tmp 当时占用 12%（59M/512M），未写满。
- 警告页数算错的发现：保留后草稿框只剩未框页，`_load` 若只按草稿框算会
  把已拆页也算成未框（测试曾断言失败：“还有 3 页”而非“还有 2 页”），
  由此补了已拆页排除与防重复拆（`_splitPagesFor`）。
- 误杀兄弟进程：排查卡顿时用 kill -9 杀过两个 flutter_tester
  （PID 25543、25568），事后从进程树看它们很可能属于并行跑测试的兄弟
  工人（.tmp-b3-p01 / b3_p11 工人），而非我的进程；此后只按自己的
  session id 停进程，未再动其他进程。被杀的两次测试对方需重跑
  （以对方实际结果为准）。

## 遗留问题
- 红色警告对“从未打开过的新导入任务”也会显示（见第 1 节末尾），
  是否收窄待定。
- `_importPdf` 末尾成功路径的 `await _db.upsertCollectTask(done)` 仍在
  两个 try 之外；若它本身抛错，异常仍会逃出 enqueue（`_failAndClean`
  自身也要写库，库坏时同样写不进）。未动，需另行决定。
- `_confirmSplit` 的已拆页判断依赖拆分任务行（sourcePath + page）；
  若用户手动删除拆分任务（连同其未整理题），该页会重新被算作可拆页——
  这是有意的（题已删，可重框），不是 bug。
- 演示库 `~/.local/share/quiz-master2/quiz-master2.db` 收尾核对 md5 仍为
  `8f7f9c64405dc6e484ac2bf8e5e1a807`，与备份
  `~/workspace/demo-db-backup/quiz-master2.db.b3-collect` 一致，未改动、
  无需恢复。
