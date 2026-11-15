# 第三次自审 — 只审第六批改动（SELF-REVIEW-3）

- 日期：2026-11-15。协调员：第三次自审协调员。
- 范围：**只审第六批改动，不审全量代码**。基线：上一次推送 `6448c45`（Batch 5，215 条路径）→ 本次推送 `38cbc4b`（Batch 6，228 条路径）；两份清单的差集只有 13 个新增 B6 报告文件，代码改动全在两批都改过的同名文件里，按 B6-*.md 报告的改动点审。第六批改动文件清单（mtime 窗口，VM 为 UTC）：`/tmp/b6-files.txt`（62 条；另有 README.md 在窗口内但清单漏列，见 SR3-31）。
- 方法：5 组并行（数据层 / 收集·整理·详情 / 错题本·复习·报告·首页 / 服务层·主题·组件 / 文档·测试质量·口径），差分走读 + 探针验证 + 单文件串行重跑测试；只审、不改代码；未提交、未推送。
- 结论：**共 35 项——P0 0 项，P1 2 项，P2 33 项**。其中 34 项是第六批引入的；SR3-25 是 B2 旧遗留（非第六批引入，任务点名核查时发现，单独标注）。
- 与前两次自审对比：第一次 134 项（P0 3）、第二次 78 项（P0 0、P1 13）、第三次 35 项（P0 0、P1 2）——第六批没有引入丢数据/崩溃级问题，P1 两项均为口径/误诊类（无数据丢失），其余全是边界、失败路径、提示与文档问题。

## P1（2 项）

### SR3-1（P1）— SR2-17 的重名拒绝可被路径写法变体绕过，恢复仍误报“文件写不进去”（来源：DATA-1）

- 位置：`lib/services/zip_archive.dart:221-224`（`readZip` 的 `seenNames` 判重）；`lib/data/db_backup.dart:447-462`（进位循环）。
- 现象：`readZip` 只按条目名的原始字符串判重。`slices//q1.png` 与 `slices/q1.png`（或 `slices/./q1.png` 与 `slices/q1.png`）在文件系统上是同一文件，判重却放行；恢复走到进位循环时，第二遍 `staged.rename(dest.path)` 因源文件已被第一遍 rename 走而抛 `FileSystemException`，恢复入口把它归为“文件写不进去”——正是 SR2-17 声称已消除的误报。
- 证据（探针实测，Linux，临时测试已删）：`readZip(buildZip([('slices//q1.png', …), ('slices/q1.png', …)]))` 不抛错，返回两个条目；`slices/./q1.png` 变体同样不抛错。端到端 `importBackupZipInto` 抛 `BackupRestoreException: 恢复失败：文件写不进去，原题库没动`——与 SR2-17 的新测试（`b5_p2_data_test.dart:1623`，断言含“已损坏”且不含“文件写不进去”）锁定的行为正好相反。数据库未动（恢复仍被安全拒绝），损害限于误诊：用户会被引向“清理磁盘空间”而不是“备份已损坏，请重新导出”。根因链：`validateZipEntryName`（`zip_archive.dart:51`）不拒空段（`//`）与 `.` 段；`readZip` 存的是原始名；staging 写盘与进位都按原始名拼路径，POSIX 下 `//` 与 `/./` 折叠成同一文件。同根因、Windows 上才可达的变体（未在 Linux 探针复现，代码分析）：大小写变体与反斜杠变体（产品跑在 Windows 上，这两类与 `//`/`.` 是同一缺口）。自家写出方无此问题（`exportBackupZipFromImpl` 用 `Set` 去重后排序写出，不产生重名条目；触发须是第三方/手工拼出的 zip）。
- 修的方向：在 `readZip` 里判重前先归一化条目名再比较：`\`→`/`、折叠连续 `/`、消解 `.` 段（与 `validateZipEntryName` 共用同一归一化函数）；如需覆盖 Windows 大小写变体，判重键再加小写折叠（仅用于比较，不改存名与落盘路径）。归一化后的键也可用于 staging/进位路径，避免同名变体在写盘阶段再次撞车。

### SR3-2（P1）— SR2-29：报告 `_isMastered` 与错题本 `_isMastered` 不同义，陈旧记录下“分布数 = 该科封面总数”不成立（来源：WRONGBOOK-1）

- 位置：`lib/modules/report/report_page.dart:193-205`（`_isMastered`）vs `lib/modules/wrongbook/wrongbook_page.dart:443-448`（`_isMastered`）；另涉 `lib/data/db_questions.dart:60-62`（`syncCauseRecordsIntoImpl`）、`:49`（`setReviewJoinedIntoImpl` 的 `_seedCauseRecordsFor`，`ConflictAlgorithm.ignore`）、`lib/data/repository.dart:30-38`（`reviewBucketOf`）。
- 现象：B6 报告称报告页新增的 `_isMastered`“与错题本同义”，不对。错题本版只看该题现存的全部 `CauseRecord`（全部已解决且无一到复查即已掌握，与 `reviewBucketOf(...) == solved` 等价，首页/封面/目录都走这条口径）；报告版则按 `q.allCauses` 逐个错因查记录（每个当前错因都必须有一条已解决且未到复查的记录）。两者只在“记录与当前错因一一对应”时才等价，而这个前提会被正常操作打破：退出复习后改错因会留下陈旧记录（`syncCauseRecordsIntoImpl` 开头即 `if (!q.reviewJoined) return;`，未加入复习的题改错因不删旧记录、不给新错因补记录）；再加入也不清陈旧记录（`_seedCauseRecordsFor` 是 `ConflictAlgorithm.ignore`、“已有记录不动”，只补缺失的）。
- 证据（可复现的两条路径，均为普通 UI 操作，无需改库）：（1）报告多算：某题错因 `[计算错误]` 已治愈 → 取消加入复习（记录保留）→ 详情页加错因 `概念不清`（无记录）→ 错题本按记录口径判已掌握（列表/封面不含它），报告按错因口径判未掌握（分布含它）→ 分布数 = 封面数 + 1。（2）报告少算：某题 `[计算错误 已解决，概念不清 待解决]` → 取消加入复习 → 详情页删掉 `概念不清`（待解决记录残留）→ 错题本判未掌握（列表/封面含它），报告只看剩下的 `计算错误` 判已掌握（分布不含它）→ 分布数 = 封面数 − 1。
- 修的方向：报告 `_isMastered` 改用与错题本/首页同一的记录口径，例如按该题现存记录算 `QuestionRepository.reviewBucketOf(records) == ReviewBucket.solved`，不再按 `allCauses` 逐因查记录；同时修正 `B6-P2-WRONGBOOK.md` 的“与错题本同义”说法与 `report_page.dart:28-35` 文件头口径注释。补一个用例：同一道题带一条已删错因的陈旧记录时，分布数与封面数一致。
- 核实说明：本条与 SR3-17 的结论以代码级证据为准——错题本组的临时探针（`test/zz_probe_sr3_test.dart`）因共享 CPU 上 `flutter test` 13 分钟无输出、编译进程几乎不动，已按确切 PID 停掉并删除探针文件，探针未完成实跑；修完后由执行员补用例并实跑验证。

## P2 — 数据层（SR3-3～SR3-9）

### SR3-3（P2）— SR2-27 的 orderBy 未覆盖全部框查询（来源：DATA-2）

- 位置：`lib/data/db_collect.dart:182-186`（`boxesForQuestionFromImpl`）、`:210-214`（`boxesForTaskPageFromImpl`）。已覆盖的是 `boxesForTaskFromImpl:199` 与 `boxesForPageImageFromImpl:232/244`。
- 现象：两个框读查询仍无 `orderBy`。SR2-27 的处方是“框查询加 orderBy”，第六批只改了其中两处。
- 证据与影响面：经全仓 grep，两函数在生产代码里没有任何调用方——`repository.dart` 只暴露 `boxesForTask` / `boxesForPageImage`，UI 只调这两处；`boxesForQuestionFrom` / `boxesForTaskPageFrom` 只有 `database.dart:469/479` 的静态转发与测试在用。因此当前无用户可见影响，属修法不彻底。另：SR2-27 测试（`b5_p2_data_test.dart:722`）的注释称“题行本身也倒序插入，钉住题 id 列表的顺序”——实际上最终框顺序只由框查询的 `ORDER BY` 决定，题 id 列表的 `orderBy: 'id ASC'`（`db_collect.dart:232`）经该测试不可观测（它只影响中间 IN 列表，不影响输出顺序）。测试本身有效，注释有夸大。
- 修的方向：两处补 `orderBy: 'page ASC, id ASC'`（与 `boxesForTask` 同口径）；或如确认两函数已无生产用途，在注释里标明“仅测试用”，避免后人误以为已覆盖。

### SR3-4（P2）— `upsertCauseRecord` 被窄化为只改 `remedy_history`，名字与公开入口未同步（来源：DATA-3）

- 位置：`lib/data/db_questions.dart:348-375`（`upsertCauseRecord`，Batch 6 改）；`lib/data/repository.dart:66`（`saveCauseRecord`）。
- 现象：行已存在时 UPDATE 只写 `remedy_history` 一列；`status` / `solvedCount` / `recheckDate` / `lastCheck` 等字段的改动被静默丢弃（UPDATE 影响 1 行，不走 INSERT，无任何报错）。方法名仍是全量 upsert，`repository.saveCauseRecord` 仍是公开入口。
- 证据：当前生产调用方只有 `saveRemedy`（`repository.dart:235-241`，只改补救历史），故无现存生产影响；但 `saveCauseRecord` 在测试播种里被用（走 INSERT 路径故不受影响）。将来任何想经它改状态的调用方都会静默丢数据——与 SR2-14 报告里“唯一生产调用方”的注释所依赖的前提（无调用方改状态）是口头约定，不是代码保证。
- 修的方向：二选一——(a) 把方法改名 `updateCauseRemedy`（并相应改 `saveRemedy` 的调用点），让窄化显性化；(b) 保留全量语义，另立 `updateCauseRemedy` 给 `saveRemedy` 用，`upsertCauseRecord` 恢复整行 UPDATE-first（cause_records 无 `review_count` 类计数列，整行写无 SR2-14 同类风险，但须与 `recordSelfCheckIntoImpl` 的事务内重算口径协调）。无论哪种，加一个用例钉住：已存在行的 `status` 改动经 `saveCauseRecord` 后是被写入还是被丢弃，二者必居其一、不得静默。

### SR3-5（P2）— `_dedupKey` 的回退分支会让不存在的路径遮蔽真实文件；大小写折叠在 Linux 下合并真实不同的文件（来源：DATA-4）

- 位置：`lib/services/import_service.dart:176-190`（`_dedupKey`）、`:213`（`seenPaths`）。
- 现象：（a，顺序依赖，Linux-only）去重键在打开文件之前算。`resolveSymbolicLinks()` 对不存在的路径抛错，回退到“绝对路径小写”。不存在的大写拼写（如 `TEST/FIXTURES/PHOTO.JPG`）回退出的键，与真实文件解析出的键完全相同。若批次里不存在的拼写排在前面，它先被处理（复制失败→failed 任务），真实文件随后被当作重复跳过——用户只得到一个失败任务，真实文件从未导入。（b，注释已披露的取舍）小写折叠对整条路径生效。Linux 下同目录仅大小写不同的两个真实文件会被当成同一文件，后者静默跳过。报告与代码注释已说明这是“病态构造”且产品跑在 Windows 上。
- 证据：代码分析（键计算是确定性的）：不存在路径回退 `File(path).absolute.path.toLowerCase()`；存在文件 `resolveSymbolicLinks()` 后 `.toLowerCase()`，两者在 cwd 相同、大小写以外无差异时相等。现有用例（`import_service_p1_fixes_test.dart:395-431`）只覆盖 `[真实, 大写]` 顺序（真实在先），未覆盖 `[大写, 真实]` 顺序。Windows 上不存在此问题（两种拼写都打开同一文件）。
- 修的方向：按平台分流键的生成——可解析时用解析后路径（大小写折叠只在该分支做，Windows/macOS 的真实同文件仍去重）；解析失败（文件不存在）时回退键用原始路径（不折叠小写），让不存在的拼写不再与真实文件撞键。代价：Linux 下 `[真实, 不存在的大写]` 会建两个任务（一个 needBox、一个 failed），这是诚实行为，与 Windows 行为不一致但各自正确。另补 `[大写, 真实]` 顺序的用例。

### SR3-6（P2）— SR2-1 的 onProgress 兜底只包了尾部两次回调，循环内两处仍可抛错（来源：DATA-5）

- 位置：`lib/services/import_service.dart:310`（复制循环内 `onProgress?.call(id, pct)`）、`:535`（`_importPdf` 渲染回调内 `onProgress?.call(task.id, pct)`）。已包 try 的是 `:419`（90%）、`:449`（图片 100%）、`:572`（PDF 100%）。
- 现象：进度回调抛错时，复制循环的 catch 把它当成“文件复制不进去”（`:317-332`：删目录、failed 任务）；渲染回调的抛错被 `_importPdf` 的渲染 catch 接住（`:543-547`：`_failAndClean`，删目录、failed 任务“渲染这份 PDF 时出了问题”）。好文件因 UI 回调异常被判失败、目录被删；外层每文件兜底 try 能防止逃出 `enqueue`（整批继续），但救不回该文件。
- 证据：Batch 5 代码里这两处同样无保护（`git show 6448c45` 对照），属 Batch 6 修法覆盖不全而非新回归。收集页的回调（`collect_page.dart:297`）有 `mounted` 检查，触发概率低，但 `setState` 在 dispose 竞态等路径下仍可抛错。
- 修的方向：两处与尾部同款包 try/catch（回调抛错只吞掉，不翻转任务状态）；或在 `enqueue` 入口把 `onProgress` 包一层永不抛错的转发函数，一处修、五处受益。

### SR3-7（P2）— B6 报告里的三处数字与代码事实不符（行为本身无问题）（来源：DATA-6 + DOCS-1 合并）

- (a) `b5_p2_data_test` 是 36→**56**，不是 36→55。`git show 6448c45` 计 36 个 `test(`，`38cbc4b` 计 56 个；新增用例名差分：新增 21 个名、改名（SR2-59）1 个，净增 20。B6-P2-DATA 的逐项表自求和也是 20（SR2-14 3 + SR2-15 1 + SR2-16 1 + SR2-17 2 + SR2-18/70 1 + SR2-58/65 2 + SR2-66 4 + SR2-67 3 + SR2-68 2 + SR2-27 1 = 20），只有标题句“新增 19 项 / 36→55”算错。B6-SUMMARY 自己的 GAPS 小节也写了 SR2-27“测试 +1”，与 C-data 小节的 55 自相矛盾；若真是 55，全量总数应为 851 而非 852。注：`B6-P2-DATA.md` 自身写 36→55 在其成文时（GAPS 的 SR2-27 在后才加）是对的，不用改；错的是事后汇总的 B6-SUMMARY。
- (b) `_failAndClean` 调用点是 **13 处**，不是报告与代码注释所说的 9 处。现文件 grep：enqueue 内 3 处 + `_importPdf` 内 10 处，定义在 `:581`。Batch 5 是 10 处。数字虽错，实质无问题：守卫在函数内部，13 处调用点全部受益。
- (c) `b5_p2_services_test` 的“15/15”是 A-import 运行时的文件规模（当时 14 项 + 新增 SR2-12 用例 1 项），D-services 随后往同一文件追加了 SR2-24/SR2-78 等分组；现文件共 25 项（18 个 `test(` + 7 个 `testWidgets(`），本次实跑 25/25 通过。报告数字按时间点无错，但作为终版总结的“文件通过数”已过时。
- 修的方向：三处数字在 B6-SUMMARY/B6-P1-IMPORT/B6-P2-DATA 里更正（报告文件，不改代码）。

### SR3-8（P2）— SR2-71“恰好 50MB PDF”用例间歇失败，未捕获到失败信息（来源：DATA-7）

- 位置：`test/import_service_p1_fixes_test.dart:344-352`。
- 现象：本次审阅中共跑该文件 9 次：前 3 次调用里失败 2 次（第 1 次组合跑的失败列表明确指向该用例；第 2 次组合跑只看到 `+75 -1`，未捕获到失败用例名），之后 7 次全部通过（3 文件组合 76/76 ×3、5 文件 103/103、单文件 16/16 ×2、单用例 ×1）。失败信息两次都未捕获，未能证实原因。
- 证据与分析：用例本身无产品逻辑可疑点——`List.filled(50MB, 0)` 真实写盘 50MB，`enqueue` 流式复制 50MB，假引擎渲染 1 页；50MB 恰等于上限，`size > limit` 不触发；`storageUsageBytes` 扫描的 `_tmp/imports` 当时约 20MB，远不到 2GB。最可能的是环境抖动（1.5 核共享 VM、/tmp 为 512MB tmpfs，50MB 真实分配+写盘+复制在负载高时撞上默认测试超时），但未经证实。不是产品 bug 的证据：同一用例随后 7 次通过，且 B6 门禁全量 852/852 通过。
- 修的方向：门禁重跑时留意该用例；如再现，保留完整失败输出再定性；可给两个边界用例（20MB 图片、50MB PDF）显式加 `timeout`，避免把环境抖动误读为回归。

### SR3-9（P2）— SR2-18 的去重集合按题/按页分作用域，跨题/跨页同 id 仍会被 REPLACE 静默覆盖（来源：DATA-8）

- 位置：`lib/data/db_collect.dart:484-499`（`seenBoxIds` 在 `for (final q in questions)` 循环内新建）与 `:556-565`（保留分支 `seenIds` 在 `for (final page in retainedPages)` 循环内新建）；插入均用 `ConflictAlgorithm.replace`，`question_boxes.id` 是 `TEXT PRIMARY KEY`（`db_schema.dart:186`）。
- 现象：同一框 id 若出现在两道题（或保留任务的两页）的入参里，第二处插入会 REPLACE 掉第一行（改写 `question_id`/`page`），第一题静默丢框——与 SR2-18/SR2-70 要堵的“静默覆盖”是同一模式，只是作用域换成了跨题/跨页。
- 证据与可达性：生产调用方（`collect_page.dart:545-643`）已按题分区——每 1 层框独占一道题，独立题内框各挂唯一目标题，同一框对象不可能进两个列表；框 id 本身含页码（`box-<task>-p<页>-<uuid8>`），跨页同 id 须伪造 id。因此当前不可达，属纵深防御缺口而非现实 bug。
- 修的方向：把两个去重集合提到 `confirmSplitIntoImpl` 的事务级（一个 `seenBoxIds` 覆盖全部题 + 保留分支），跨题/跨页重复也跳过（保留第一个）；或把两处插入的 `ConflictAlgorithm.replace` 改为 `fail`，让越界重复显式抛错走事务回滚（与 SR-P2-10 的防呆口径一致）。

## P2 — 收集 / 整理 / 详情（SR3-10～SR3-16）

### SR3-10（P2）— SR2-3：事务成功、rename 前进程被杀，DB 与磁盘切片不一致且无自愈（来源：COLLECT-1）

- 位置：`lib/modules/detail/question_detail_page.dart:397-429`（`_reworkBoxes`）。
- 现象：事务提交（框 + `slicePath`/`sliceWidth`/`sliceHeight` 已是新值）与 `File(tmpAbs).rename(sliceAbs)`（`:417`）之间没有原子性保障。进程恰好死在这两步之间时，库里记的是新切片的尺寸与路径，磁盘上的 `slices/<qid>.png` 仍是**旧图**。下次打开详情页，题按新尺寸展示旧图；没有任何代码会发现或修复这种不一致。
- 证据：事务成功后 rename 前无任何持久化标记（如 generation / 校验），失败/中断后无法区分“旧图 + 新框”是合法状态还是中断残留。孤儿扫描（`lib/data/db_orphans.dart`）不覆盖此情形：旧切片仍被 `slice_path` 引用，不是孤儿；临时文件 `.tmp-*` 是孤儿，但旧图不是。残留的 `.tmp` 文件本身会被扫描发现，但它救不了“库已新、图仍旧”的不一致——删掉 `.tmp` 后旧图照样顶着新尺寸被展示。
- 修的方向：任选其一：(a) 启动/打开详情页时校验切片实际尺寸与库里 `sliceWidth/sliceHeight` 是否一致，不一致时按当前框重裁一次（或提示重框）；(b) 把“已 rename”做成可恢复的两阶段提交（如先把 `.tmp` 路径也写进一个待处理标记，启动时对有标记的题补做 rename）；(c) 至少在文档/复核清单里把“事务提交后、rename 前被杀”记为已知崩溃窗口，与 `.tmp` 孤儿分开列（目前 B6 只认了 `.tmp` 孤儿这一半）。

### SR3-11（P2）— SR2-3：`_reworkBoxes` 里读页图与裁切片在 try 外，失败时无提示、无反馈（来源：COLLECT-2）

- 位置：`lib/modules/detail/question_detail_page.dart:361-363`，调用点 `:1340`（`onPressed: _reworkBoxes`，无 try）。
- 现象：`File(pageAbs).readAsBytes()`（`:361`）与 `cropBoxPng(pageBytes, first)`（`:363`）都不在 try 里。页图存在但读不出（权限/IO 错误、文件损坏截断）或框落在图外时，异常直接抛到按钮回调：无 SnackBar、用户看不到任何反馈，本次重框会话（编辑器里刚改好的框）白做，只能重进编辑器再改一遍。库本身不受影响（事务还没跑），所以只是 P2。
- 证据：`cropBoxPng` 明确会抛：`lib/services/page_image_pipeline.dart:158-160`，裁后宽/高 ≤ 0 时抛 `ArgumentError('框 … 落在页图外，裁不出切片')`；`_decode`（`:211`）在页图字节损坏时同样会抛。同一段里临时文件写盘有 try/catch（`:380-386`，报“切片写不进去”），事务失败有 try/catch（`:403-410`），rename 失败有 try/catch（`:417-427`）——唯独读图 + 裁切这两步没有，形成不对称缺口；B6-P1-DETAIL.md 称该段“整段按规定修法重写”，缺口是重写时留下的。
- 修的方向：把 `:361-363`（含 `resolveDataPath` 判空后的读 + 裁）包进 try/catch，失败报“重新框选失败：页图读不出来/切片裁不出来，请重试”并 return；补一个用例：用损坏页图字节（或 `cropBoxPng` 抛错的桩）断言提示出现且 `takeException()` 为空。

### SR3-12（P2）— SR2-4：中心点挂接在框重叠时平局静默取先到者，且无距离上限（来源：COLLECT-3）

- 位置：`lib/modules/collect/collect_page.dart:768-795`（`_nearestLayer1Box`），调用点 `:630-645`。
- 现象：（1）**重叠平局**：独立内框中心同时落在两个重叠的 1 层框内时，两个距离都是 0，`d < bestDist` 的严格小于使列表先到的框静默获胜，没有任何提示或二次判据。密集排版下框重叠是已知高频情形（验收清单里单列的检测质量问题），“挂错题”就发生在这个最常见的场景里。（2）**无距离上限**：只要本页有 1 层框，函数必返回一个框，哪怕独立内框中心离所有题都很远（如页眉/页边手画的 stray 框）。以前这种框在确认时被丢弃（可见的丢失），现在会被静默挂到最近的题下（不可见的错挂）。
- 证据：`_nearestLayer1Box` 无距离阈值、无面积/相交度比较；平局只靠 `for` 循环顺序（画框/检测顺序），与框的语义无关。`_confirmSplit` 里对 `target == null` 的 `continue`（`:640`）在 `layer1` 非空时永远走不到，等于是“必挂”。
- 修的方向：平局/重叠时改判据为内框与候选框的相交面积最大者（或面积最小的命中框），仍平局时把该内框留在 `standaloneInner` 并在确认后提示“有 1 个题内框同时落在两道题里，请手动指定归属”；另加距离上限（如中心到框的最短距离超过页宽/高的 0.25 即不挂，确认后提示用户手动处理），避免远处 stray 框被强制归属。

### SR3-13（P2）— SR2-20：候选检测框池未过滤 + IoU > 0.05 阈值过低，邻题检测框可把目标框拽走且不提示（来源：COLLECT-4）

- 位置：`lib/modules/collect/box_editor.dart:715-816`（`_restoreAutoBoxForRework`），候选池与阈值约 `:750-760`，部分匹配提示约 `:795-800`。
- 现象：`detected` 取的是本页**全部** 1 层检测框（含同页其他题的框——重框模式下只读框就在同一页上），而 `targets` 只有当前题的框。某目标框的真实检测缺失时，只要邻题的检测框与它有 > 0.05 的 IoU，就会按贪心认领把它“恢复”到邻题的位置上；`matches` 计入该目标，`missed` 不增加，用户收不到“没找到对应的检测框”提示，框错位要靠肉眼发现。
- 证据：阈值 0.05 极低：一个角上轻微搭边的检测框即可认领，换算后目标框整体跳到检测框几何上，位移可达半页以上。贪心按 IoU 降序虽能防止两道题抢同一个检测框，但防不住“目标 A 的真实检测缺失 → 邻题检测框与 A 有微弱重叠 → 被 A 认领”；邻题的检测框本来就该由邻题的目标认领，但邻题在重框模式下不是 target，不参与认领，池子却对它开放。
- 修的方向：二选一或并用：(a) 提高阈值（如 0.3，并在提示里说明阈值）；(b) 候选池排除中心落在其他题只读框内的检测框（重框模式下 `widget.readOnlyBoxes` 已有）；(c) 认领后校验位移，中心位移超过阈值时视为未匹配、按 missed 提示。补用例：双题同页、一题检测缺失、邻题检测框与目标框微弱重叠 → 断言目标框不动且弹“没找到对应的检测框”提示。

### SR3-14（P2）— SR2-20：恢复自动框时独立题内框不跟随 1 层框移动（来源：COLLECT-5）

- 位置：`lib/modules/collect/box_editor.dart:715-816`（`_restoreAutoBoxForRework` 的 `setState` 段），对比 `lib/modules/detail/question_detail_page.dart:332-336`（详情页把无父框内框传进 `initialStandalone`）。
- 现象：恢复时只有 `_inners[key]`（有父框的内框）按新旧框相对位置换算跟随（并 `_clampInner` 钳进新框）；`_standaloneInner` 里的无父框内框原地不动。重框模式下这些独立内框本就属于当前题（详情页按 `questionId == q.id` 挑出来传进来的），1 层框平移/缩放后它们与题的相对位置全错。
- 证据：`setState` 段只处理 `_inners[key]`，全文无对 `_standaloneInner` 的写操作。后果分两支：多题同页时，确认拆题的 SR2-4 会按**新**中心点重新挂接，错位后的内框可能被挂到邻题下（SR3-12 的挂错在确认时二次放大）；单题页则区域换算（`layer2BoxToSliceRect`）按错位坐标算，内框被钳到切片边缘或直接无面积回退示意框。
- 修的方向：对中心落在旧目标框内的独立内框做与 `_inners` 相同的相对位置换算（或至少整体平移同一 delta），再 `_clampInner` 钳进新框；中心落在旧框外的独立内框保持不动。补用例：重框恢复后断言独立内框随 1 层框同向移动。

### SR3-15（P2）— SR2-5：`_batchTagRedo` 的快照同步是全有或全无，循环中途写库失败会让已落盘的标签被后续批量操作抹掉（来源：COLLECT-6）

- 位置：`lib/modules/organize/organize_page.dart:2286-2306`（`_batchTagRedo`）。
- 现象：保存循环（逐题 `repo.save`）没有任何 try；同步回 `_questions` 的 `setState` 只在整个循环成功后执行。循环中途某题写库失败抛错时，前面已保存的题在库里已有 `#需重做`，但弹窗内的 `_questions` 仍是旧行；用户随后在同一弹窗里做批量加文件夹/批量确认（整行覆盖），就会把刚落盘的标签抹掉——正是 SR2-5 要根治的那种抹除，只是换了一条触发路径（失败路径）。
- 证据：`_batchTagRedo` 的 `setState` 在循环之后、无 `try/finally`；`_batchAddFolder` 是同款结构（旧有），但 B6 的修复恰恰依赖“保存后同步”这一步必跑，失败路径下它不跑。注意 `_saveCurrent`/`_trySaveCurrent` 的调用方拦停逻辑管不到弹窗内的批量路径。
- 修的方向：每保存成功一题就地同步该行进 `_questions`（循环内 `setState` 或先改本地副本、循环结束统一 `setState` 一次并用 `try/finally` 保证执行）；或失败时把已保存的题 id 记下来、同步已保存子集并提示“部分保存失败”。补用例：桩 repo 第二题 `save` 抛错 → 断言第一题的标签在弹窗快照里仍在、后续批量加文件夹后标签不丢。

### SR3-16（P2）— SR2-26：“拦住”只拦 6 处页内动作，离页路径不保存，持续保存失败时用户仍可走出页面并静默丢编辑（来源：COLLECT-7）

- 位置：`lib/modules/organize/organize_page.dart:334-344`（`_trySaveCurrent`）、调用点 `:345/352/382/401/460/476`；离页路径见 `:150-160`（`dispose` 只 dispose 控制器）与全文件无 `PopScope`/`WillPopScope`。
- 现象：B6-P1-QUEUE.md 论证“拦住”时称“改动真正留在内存里……行为与提示一致”，但这只在用户留在整理页内成立。保存持续失败（如写库一直抛错）时，用户在页内确实切不了题、开不了队列、进不了详情，但点左导航/返回即可离页；离页时没有任何保存尝试与未保存提示，表单改动静默丢失——“拦住”防的是页内静默丢，没防住离页静默丢。
- 证据：6 处调用点全部正确处理了 `false`（逐个核对，无忽略返回值的调用点）；但 `_confirmCurrent`（`:359`，已知遗留）与离页路径不在此列。`dispose`（`:150-160`）只释放控制器，不调 `_saveCurrent`；全文件无 `PopScope`/`WillPopScope`，`app_shell` 侧也无针对整理页的离页拦截。
- 修的方向：给整理页加离页守卫（`PopScope` + 切导航前尝试保存；保存失败时弹“有未保存的改动，保存失败，仍要离开吗？”由用户决定去留），或至少在 B6-P1-QUEUE.md 的“拦住”论证里补一句适用边界（只保页内动作，不保离页）。后者是文档级修正，前者是产品级修正；按 Meng 的“拦住”定调，建议先文档，后者另立项由 Meng 定（见汇总“需 Meng 定的口径项”）。

## P2 — 错题本 / 复习 / 报告 / 首页（SR3-17～SR3-20）

### SR3-17（P2）— SR2-33：按组进会话的文案“学科名 · 错因”与实际作用域不一致（来源：WRONGBOOK-2）

- 位置：`lib/modules/review/review_page.dart:496-520`（`_startSession` 的 `fromGroup` 分支）与 `:430-460`（`_buildBlocks`）；对照 `:542-559`（`_scopeLabelForBlocks`）。
- 现象：B6 把按组进会话的范围文案改成 `'${学科名} · ${错因}'`，注释称“按组进会话只治该组一个错因”。但实际会话块是 `_buildBlocks(_filtered, onlyCause: fromGroup.cause)`——`_filtered` 是当前筛选下的全部分组，`_buildBlocks` 会把其中**每一个**含该错因的分组里的题都建成块，`bi` 只是跳到该组的首个块。于是会话作用域是（当前筛选 × 该错因），从该组开始、随后继续治其他学科同错因的题；文案却全程写着该组的“学科名 · 错因”。按 `_scopeLabelForBlocks` 对实际块集算，跨学科单错因时应得 `错因「计算错误」`，而不是 `数学 · 计算错误`。例：无筛选时数学、英语各有一道 `计算错误` 待治题，点数学组的“开始解决”，会话共 2 道题（`第 1 / 2 道题`），第二道是英语题，但元信息行全程写“数学 · 计算错误”。
- 证据：`_buildBlocks` 里 `allowed` 由 `_filtered` 的全部分组建成，`onlyCause` 只过滤错因、不限制学科；`bi` 的循环只定起始块。既有用例 `test/review_page_test.dart:713` 抓不住这一点——该库里只有 q2 一道题带 `计算错误`，会话恒为 1 块。
- 修的方向（二选一）：(a) 文案按实际块集算，即按组进会话也用 `_scopeLabelForBlocks(blocks)`（跨学科时自动退为 `错因「…」`）；或 (b) 把块集真正收窄到该组（`_buildBlocks` 只传该组），让文案与行为都按组来。另给既有用例加一道英语同错因题，断言会话题数与文案。
- 备注：`causesPerSession` 上限截断是同一类文案失真（截断后会话可能不含该组任何题，文案仍写该组），修 (a) 时一并覆盖；断点恢复分支仍用 `_scopeLabelForBlocks`，不受影响。
- 核实说明：与 SR3-2 同样，本条结论以代码级证据为准（错题本组探针因共享 CPU 争抢未跑通，见 SR3-2 备注）；修完后由执行员补用例并实跑验证。

### SR3-18（P2）— SR2-28：搜索态缝隙拖拽拒收全程无任何提示（来源：WRONGBOOK-3）

- 位置：`lib/modules/wrongbook/wrongbook_directory.dart:271-279`（`_buildGapTarget` 的 `onWillAcceptWithDetails`）。
- 现象：文件夹搜索有关键词时缝隙一律 `return false`，状态正确（不调序、不保存，`test/wrongbook_page_test.dart:1902` 已钉住），但用户侧零反馈：拖动时缝隙不高亮、不提示，松手后什么都不发生。搜索态是用户正在主动操作的状态，拖拽平时又可用，静默拒收容易被当成“拖拽坏了”。
- 修的方向：在搜索框附近或目录顶加一句静态提示（例如搜索有关键词时显示“搜索时不能调顺序，先清空搜索”），或在缝隙拒收时给一个轻提示；`DragTarget` 本身没有“被拒”回调，提示要放在搜索态的文案上，不要为此改拖拽结构。
- 备注：静默拒收是本文件既有风格（跨层缝隙拒收 SR-P2-43 同款），本条只要求补一句可感知的说明，不改拒收行为。

### SR3-19（P2）— SR2-30：B6 报告“preview.items 里不再有目录本身”不严谨；failed 目录仍以目录形式进 items，清理计数按 1 项算（来源：WRONGBOOK-4）

- 位置：`lib/modules/settings/settings_page.dart:556-562`（`walk` 的 failed 分支）与 `:528-539`（`add`）、`:624-644`（`_clearCache`）。
- 现象：B6 只改了 cache/thumb/tmp 目录分支（递归进目录逐个计数），但 `walk` 开头的 failed 分支是 `if (lower.contains('failed') || lower.contains('import-error')) { add(e, 'failed'); continue; }`——`e` 可以是目录，`add` 会把它整个塞进 `preview.items`（字节数按递归合计），`_clearCache` 再递归删掉它、只计 1 项。于是“已清理 N 项缓存”与实际删掉的文件数在该分支上仍不一致；`_cacheCleanedMb = preview.mb` 在个别文件删失败时也会虚高（先于 B6 存在的小口径差）。
- 证据：代码走读。实际情况是当前代码里没有已知的 failed 目录生产者（`import_service.dart` 的 failed 是任务状态，不是目录名；`collect_page.dart` 亦然），所以这条目前大概率走不到目录分支，影响面限于用户自放的同名目录。
- 修的方向：failed 分支也与 B6 的 cache 分支同款处理——目录递归进、文件逐个计；或至少在注释里写明 `preview.items` 仍可含 failed 目录、与“不再有目录本身”的说法对齐。低优先级。

### SR3-20（P2）— SR2-61：真实仓储首页用例只断言焦点卡总数，未断言分科行；tearDown 注册在播种之后（来源：WRONGBOOK-5）

- 位置：`test/b5_p1_1_subject_counts_test.dart:222-271`（SR2-61 用例）；`test/home_page_test.dart:105-110`（`pumpHome` 的 `repo` 参数放宽与 `settle` 参数）。
- 现象（次要测试缺口）：用例本身是真接线——真实 `QuestionRepository` + 内存库、经仓库写方法播种、先断言仓储层数（`dueToday` = `{q1,q2,q3,q8}`、`homeRevCounts` = `{math:3, english:1, politics:0}`）再泵首页断言 `4 道要复习` / `待解决 2 道 · 复查 2 道`——`pumpHome` 放宽参数只是配套改动，这点已确认无问题。但 widget 侧只断言了焦点卡两行总数，分科行（数学/英语各自的今日到期、复习中、已掌握）仍只由 FakeRepo 用例覆盖；另外 `addTearDown(AppDatabase.resetForTest)` 注册在 `runAsync` 播种之后，若播种抛错，测试库单例会残留（目前无害：该用例是本文件最后一个用例，且各测试文件分进程跑）。
- 修的方向：补断言分科行文案（与 FakeRepo 的同名用例对齐）；把 `addTearDown` 移到播种之前。低优先级。

## P2 — 服务层 / 主题 / 组件（SR3-21～SR3-25）

### SR3-21（P2）— SR2-31：金角 25° 保护在第 15 科起静默失效，36 步兜底返回近乎撞色的颜色（来源：SERVICES-1）

- 位置：`lib/modules/subjects/subjects_page.dart:322-341`（`_addSubject` 的 `orElse` 金角循环）；`B6-P2-SERVICES.md`“第 14、15…科生成色同样受 25° 阈值保护”的说法不成立。
- 现象：第 13 科（284°、`0xFFB34CD9`，最小色相距 31.8°）与第 14 科（135.5°，最小色相距 31.8°）都合规；但从第 15 科起，`guard < 36` 的 37° 步进在 36 步内找不到任何与全部已用色拉开 ≥25° 的色相，循环退出后**直接返回仍违规的颜色**，没有任何提示或降级。色相距一路跌到 0.7°（第 23 科 37.0°，与琥珀 `0xFFF59E0B` 的 37.7° 只差 0.7°，肉眼无法区分）。
- 证据：临时探针（真实 Dart `HSVColor.fromAHSV(…).toColor()` + `HSVColor.fromColor(…).hue`，与产品代码同一公式；色相距按 SR2-56 测试的做法取生成色实际 hue）复算 13–30 科：第 15 科 17.0°/14.0°、第 16 科 154.5°/12.7°、第 17 科 292.0°/8.1°、第 20 科 344.5°/5.0°、第 23 科 37.0°/**0.7°**、第 30 科 279.5°/4.3°，15–30 科全部耗尽 36 步（仅 25 科 18.5°、其余均 < 15°）。根因是 37° 步进的格点有限：14 色各占 50° 禁区后，36 个格点全部落在禁区内——不是步进次数不够，而是步进格点本身撞墙。
- 修的方向：二选一，(a) 耗尽后不再原样返回，改在 1° 细粒度上扫描取“与全部已用色最小色相距最大”的色相（14 色下理论最优仍有约 12–13° 空隙，至少做到最优而非任意）；或 (b) 明确降级语义：耗尽时放宽阈值（如 10°）并在代码注释写明“15 科后 25° 不可达”。无论哪种，补一个 14–16 科的用例钉住“耗尽不静默返回违规色”（现有 SR2-56 只钉第 13 科）。修法 (a)/(b) 由 Meng 定（见汇总“需 Meng 定的口径项”）。

### SR3-22（P2）— SR2-35：QmChip × 区上下各留约 1.55px 死区，“整个芯片都可点”不成立（来源：SERVICES-2）

- 位置：`lib/widgets/uikit.dart:650-690`（`QmChip` 双区分支 `Row`）。
- 现象：标签区识别器高 = 文字 13×1.2 + 上下各 4 = 23.6px，× 区识别器高 = 字形 12.5×1 + 上下各 4 = 20.5px；`Row` 默认 `crossAxisAlignment: center`，行高取 23.6px，× 识别器上下各留 (23.6 − 20.5) / 2 ≈ **1.55px**（1.0 倍字号；1.3 倍字号下约 2px）不被任何识别器覆盖。双区模式下外层 `_QmPressable` 不装 Tap 识别器（`childHandlesTap: true`），所以点这条细缝**无回调**，但外层 `Listener` 仍会给出按压视觉——正是 SR2-35 要消灭的“按下无反应 + 有按压闪烁”，以缩小版残留。SR2-35 测试只点 `chipRect.center.dy`（垂直居中）与标签/× 间隙中点，探不到这条缝。
- 证据：尺寸算式——旧布局总宽 12 + 文字 + 4 + 字形 + 12、总高 23.6px，与新布局逐项相等（芯片总尺寸不变的说法属实）；但旧布局死区由外层 `_QmPressable` 的 `onTap` 兜底（点缝触发标签回调），新布局外层无手势，缝变成真死区。`deletableChipPaddingH/V` = 12/4，`chipFontSize` = 13、`captionFontSize` = 12.5、`controlLineHeight` = 1.2，`QmGlyph` 的 `Text` 行高恒为 1。
- 修的方向：`Row` 加 `crossAxisAlignment: CrossAxisAlignment.stretch`（两识别器撑满行高），或给 × 识别器的 `Padding` 外包一层与标签区等高的 `SizedBox`；补一个探针用例点 × 区顶部/底部边缘（`chipRect.top + 1` 与 `chipRect.bottom - 1` 处 × 的横坐标）断言 `deleted` +1。

### SR3-23（P2）— SR2-73：测试屏障以 error 完成时，`_loadFuture` 被永久毒化，后续检测不再重试加载（来源：SERVICES-3）

- 位置：`lib/services/yolo_onnx_service.dart:225-245`（`_ensureLoaded` / `_loadOnce`）。
- 现象：`_loadOnce` 里 `await gate.future` 在 `try` 块之外；若 gate 以 error 完成，`_loadOnce` 的 Future 以 error 完成，`_ensureLoaded` 的 `await future` 抛错，`if (!ok) _loadFuture = null` 一行被跳过——失败的 `_loadFuture` 永远留在原地。此后每次 `_ensureLoaded` 都直接返回同一个失败 Future，每次检测都走 fallback，且 `_loadAttempts` 不再增长，**加载永不重试**，直到重启或调 `resetLoadStateForTest`。
- 证据：临时探针实测——gate 先 `completeError(StateError)`：第一次检测 fallback、`loadAttempts == 1`；第二次检测仍 fallback、`loadAttempts` 仍为 1（`POISONED=true`）。对照：正常加载失败（模型缺失）走 `try` 块内路径，`_loadFuture` 会被清掉，下次检测会重试（SR-P1-16 行为不受影响）。
- 定级说明：生产 `loadGateForTest` 恒为 null（全仓 grep：除 `yolo_onnx_service.dart` 本身外只有 `test/yolo_onnx_service_test.dart` 引用它），所以生产不可达；风险只在测试侧——将来某个测试给 gate 包超时/取消并以 error 完成时，会毒化之后同文件的所有测试。修的方向：把 `await gate.future` 移进 `try` 块内，或在 `_ensureLoaded` 里用 `future.then((ok) { if (!ok) _loadFuture = null; }, onError: (_) => _loadFuture = null)` 清掉失败的 future。

### SR3-24（P2）— SR2-73：串行队列无超时，单次推理卡死会堵住后续全部检测（来源：SERVICES-4）

- 位置：`lib/services/yolo_onnx_service.dart:153-165`（`_detectQueue` + `_serializedDetect`）。
- 现象：`_serializedDetect` 把每次 `_detect` 链在一条静态 Future 链上，没有任何超时或取消。若某次原生 `runAsync` 迟迟不回（驱动/模型异常），该次检测挂起的同时，**之后所有检测也永久排队**——第六批之前，一次卡死的推理只卡住自己的调用方；改动后它会放大成全局检测停摆。链本身不会被失败毒化（`run.then<void>((_) {}, onError: (_) {})` 已吞掉错误，后续检测仍能跑——这一点已静态核对，无问题），缺的是“卡死”这一分支。
- 证据：代码阅读——`_detect` → `_run` → `session.runAsync` 全程无 `timeout`；`detectPage` 也无超时。属于新引入的失效模式放大，发生概率低（`runAsync` 卡死本身是假设场景），故 P2。
- 修的方向：给队列里的单次推理加超时（如 60s，超时按推理异常走 fallback 并放行队列），或在报告里写明“接受此风险：单次推理卡死即全部检测停摆”作为已知取舍。注意不要把超时做成取消原生推理（onnxruntime 无取消语义），超时只应放行队列、不应假装推理已结束。是否加超时由 Meng 定（见汇总“需 Meng 定的口径项”）。

### SR3-25（P2，非第六批引入 · B2 遗留）— SR2-36 口径外仍有一处直接返回存色：错题本紧凑行在深色下用亮色存色画学科名（来源：SERVICES-5）

- 位置：`lib/modules/wrongbook/wrongbook_list.dart:942-945`（`_prowMetaLine`）。
- 现象：`DesignTokens.subjectInk(q.subjectId, Brightness.light, subject.color)` 把亮度写死成 `Brightness.light`。`subjectInk` 在亮色分支下对新学科直接返回 `stored` 原值——于是深色主题里，错题本紧凑行 / 归档行的学科名仍是饱和亮色存色（如化学紫 `0xFF7C5CFC`），与 SR2-36 刚修掉的 `subjectLabelColor` 第三入口是同一类缺陷，只是换了个入口。
- 来源说明：**不是第六批引入的**——该行自 B2 起就在（注释“B2 补充”），第六批未动此文件此行；列在这里是因为本次任务点名要求“逐一核实全部调用点”，它是 13 处存色调用点里唯一未雾化的一处。其余 12 处（`home_page.dart:644-647`、`report_page.dart:673`、`review_page.dart:1118/1395`、`subjects_page.dart:631/651/724`、`uikit.dart:566/590`、`app_shell.dart:528`、`widgets.dart:751`）全部传真实 `brightness`，深色下均走雾化，已逐一核对。
- 修的方向：把 `Brightness.light` 改成 `Theme.of(context).brightness`（与同文件注释“纸面取浅色档”的意图冲突时以 SR2-36 口径为准，深色下雾化）；建议作后续项而非第六批回炉，因为它不在第六批改动文件清单的修法内。

## P2 — 文档 / 测试质量 / 口径（SR3-26～SR3-35）

### SR3-26（P2）— 整理页测试基数写错：“原 30 + 新增 9”应为 29+9（来源：DOCS-2）

- 位置：`docs/ui-replication/B6-SUMMARY.md` A-queue 小节（“整理页测试 38/38（30 + 9 新增，含 1 个对照）”）；同款错误在 `docs/ui-replication/B6-P1-QUEUE.md`（“38/38 通过（原 30 + 新增 9”）。
- 现象：基数 30 是错的，38 的总数是对的。
- 证据：`git grep` 计数：`6448c45` 时 `test/organize_page_test.dart` 为 29 项；diff 为 +9/−0；29+9=38。30+9=39，与 38 对不上。
- 修的方向：两处均改为“原 29 + 新增 9 = 38”。

### SR3-27（P2）— `docs/代码地图.md:10` 的 Batch 6 状态过期：仍写“第六批修复进行中”（来源：DOCS-3）

- 位置：`docs/代码地图.md:9-11` 头注（“…第六批修复进行中，其改动未提交”）。
- 现象：与同批已更新的另外两处状态表述不一致。
- 证据：`docs/CODEBUDDY.md:44` 与 `docs/四方分工.md:60-61` 已由协调员同步为“第六批修复已完成、在工作树里，未提交、未推送”；代码地图头注仍写“进行中”。Batch 6 完成是总结全文的前提，该句已过期。
- 修的方向：头注同步为“第六批修复已完成（未提交、未推送，等 Meng 批准）”，或按 SR3-35 的推送后状态一并更新。

### SR3-28（P2）— B6-SUMMARY“遗留”漏收 7 处阶段报告级的遗留（来源：DOCS-4）

- 位置：`docs/ui-replication/B6-SUMMARY.md` 末尾“遗留（未修 / 需另定）”小节。
- 现象：以下 7 条只在各阶段报告的“遗留问题”小节里，总结遗留未收录（总结的遗留不是全集，但这 7 条都是未解决的已知缺口，漏掉会让验收方以为已无遗留）：
  1. A-import：EXIF 镜像方向分支的“失败写库”未单独立用例（与“解不开图片”分支共用路径，未做触发器用例）——`B6-P1-IMPORT.md` 遗留第 2 条。
  2. A-detail：B5 的旧 P2-3 测试仍只覆盖“无旧切片”场景，有旧切片的覆盖在 `detail_page_test.dart`，两处未合并——`B6-P1-DETAIL.md` 遗留第 3 条。
  3. A-split：已拆过的页（`alreadySplit`）上后画的独立内框，确认时仍随 `continue` 静默丢弃——`B6-P1-SPLIT.md` 遗留第 1 条。
  4. A-queue：`_jumpToQuestion` 失败时弹出层已先关闭，用户需重开队列再跳——`B6-P1-QUEUE.md` 遗留第 2 条。
  5. D-services：SR2-38 的 `minSize: true` 分支里 `(minSize && …)` 判断恒为真（`!minSize` 已提前返回），留作原样——`B6-P2-SERVICES.md` 遗留第 2 条。
  6. D-services：SR2-31 的金角步进只在第 13 科钉死字面值，第 14、15…科未逐个断言——同文件遗留第 3 条（与 SR3-21 同一缺口的不同侧面：SR3-21 是产品行为问题，本条是总结遗留漏收）。
  7. GAPS：SR2-73 的 500ms 等待是“等第二次检测到达 `_ensureLoaded`”的经验余量，解码极慢的环境下计数可能为 2——`B6-P2-GAPS.md` SR2-73 补跑重点。
- 修的方向：补进总结遗留（或在各阶段小节内保留并在遗留小节注明“另见各阶段报告”）。注：A-dropdown 的 `_filterExamId` / 复习页 `_subjectFilter` 未覆盖已在总结 A-dropdown 小节内写明，不重复。

### SR3-29（P2）— B6-SUMMARY“遗留”中 SR2-16 一条已过时：影响面已由第三次全量确认（来源：DOCS-5）

- 位置：`docs/ui-replication/B6-SUMMARY.md` 遗留（“SR2-16 对既有备份 fixture 的影响面待全量确认”）。
- 现象：该条仍列为待办，但第三次全量 852/852 已通过，其中含 `p1_schema_backup_test.dart`、`s8b4_backup_migration_test.dart` 等既有备份用例，影响面已确认无回归。
- 证据：总结“最终验证”小节自述第三次全量 852/852 通过、演示库 md5 不变；同一份总结的遗留仍写“待全量确认”，前后矛盾。
- 修的方向：该条移出遗留或标注“第三次全量已确认，无回归”。同条前半句“SR2-15 并发测试依赖 sqflite 事务串行化”是已知脆弱性而非待办，建议改述为“并发用例依赖串行化语义，换库后端时需复核”，不要与待办混列。

### SR3-30（P2）— 工作树曾留有 4 个未入库的 TEMP 探针测试文件（来源：DOCS-6；协调员已核实清理完毕）

- 位置：工作树 `test/zz_probe_4way_test.dart`、`test/zz_probe_gate_test.dart`、`test/zz_probe_golden_test.dart`、`test/zz_probe_sr3_test.dart`（各 1/1/1/2 个用例，共 5 个）。
- 现象：4 个文件均未入库、不在已推提交 `38cbc4b` 内，头注均写“TEMP PROBE（delete after run）/ 临时探针（跑完删除）”，但审阅期间仍留在树里；B6 各报告均未提及这批探针。
- 证据：`git ls-tree 38cbc4b -- test/` 无此 4 文件；mtime 为 2026-11-15 04:18–04:20 UTC，晚于 38cbc4b 推送（约 03:41 UTC），故不影响已推的 852/852 结论；但在当时脏工作树里再跑全量会是 857 个用例，且探针内容（4 路并发真实推理、gate 报错是否毒化 `_loadFuture`、金角 13–30 科复算）无报告记录结论。
- 处理：协调员 2026-11-15 04:35 UTC 核实，`test/zz_probe_*` 已全部删除（各探针属主自行清理），当前工作树无残留；本次统一验证的全量计数以干净树为准。修的方向：以后探针结论记入报告后立即删除；引用 852 基线时注明以已推提交为准、不是脏工作树。

### SR3-31（P2）— 任务清单 `/tmp/b6-files.txt` 漏了 README.md（B6 改动文件之一）（来源：DOCS-7）

- 位置：`/tmp/b6-files.txt`（窗口 01:30–04:00 UTC，62 条）。
- 现象：清单无 README.md，但它是第六批改动文件。
- 证据：`README.md` mtime 2026-11-15 01:40:42 UTC，在窗口内；`git diff 6448c45..38cbc4b --name-only` 共 63 个文件，逐项比对后仅缺 README.md；其改动是 SR2-9（`demoQuestions()` 已删，见 `B6-P1-DOCS.md` 与 diff）。本次审阅中该文件由文档组覆盖（SR2-9 核对无问题），未漏审。
- 修的方向：清单补一条 README.md。本项不是 B6 报告本身的问题，但按清单核对会漏审该文件，特此记录。

### SR3-32（P2）— B6-P1-DOCS.md 的“已于 Batch 5（SR-P2-13）删除 3 处”验证口径小差（来源：DOCS-8）

- 位置：`docs/ui-replication/B6-P1-DOCS.md`“全局核对”小节。
- 现象：报告称该说法 3 处，但按其所写的字面 grep 只能命中 2 处。
- 证据：`README.md:61-64` 的该句被换行断开（“…`demoQuestions()` 已于 Batch 5 / （SR-P2-13）删除…”），字面 grep 只命中 `docs/decision-log.md:36` 与 `docs/代码地图.md:119` 两处；措辞本身三处均已就位，错的是验证方法的宣称，不是改动。
- 修的方向：报告措辞改为“3 处（README 一处因换行断开，字面 grep 命中 2 处）”，或改用跨行核对。

### SR3-33（P2）— 多处行号引用已漂移（不影响结论，仅备查）（来源：DOCS-9）

- 位置：B6 各报告与 B6-SUMMARY 的行号引用。
- 现象：以下引用与当前文件行号不符（均为后续改动顶动行号所致，报告成文时部分已漂移）：
  - `B6-P1-DOCS.md`：代码地图 `:477`→实测 `:478`、`:118`→实测 `:119`。
  - `B6-P1-DETAIL.md`：B5 的 P2-3 回归测试组“约 :891-960”→实测 `test/b5_p2_collect_test.dart:1041`。
  - `B6-SUMMARY.md` A-detail：“`replaceQuestionBoxesAndSlice` 实际在 `db_collect.dart:325`”→实测 `:338`。
  - `B6-SUMMARY.md` GAPS：`test/home_page_test.dart:110`→实测 `pumpHome` 在 `:111`。
- 修的方向：不逐条改旧报告；后续引用以 grep/符号为准。B6-SUMMARY 的 `:325` 一处建议随手改为 `:338`（它是总结正文，不是历史记录）。

### SR3-34（P2）— SR2-56 测试的 hue 距离 helper 与产品 `_hueDistance` 同公式复写（有兜底，记为写法弱点）（来源：DOCS-10）

- 位置：`test/subjects_page_test.dart:686` 起（本地 `hueDistance`）对照 `lib/modules/subjects/subjects_page.dart:63`（`_hueDistance`）。
- 现象：测试内复写了与实现相同的环形 hue 距离公式（差值 %360、>180 取补）；若产品公式算错，测试会同错——与 SR2-55 曾有的问题同类。
- 证据：同一用例先断言了字面值 `0xFFB34CD9`（`repo.subjectsList[12].color`），生成结果已被独立钉死；hue 循环只是第二道检查，风险已兜底。
- 修的方向：保留字面值断言为主；若日后重构，hue 循环改为只断言字面值，或改用与实现无关的 hue 计算，不再在测试内复写产品公式。

### SR3-35（P2）— 推送后状态过期：CODEBUDDY.md / 四方分工.md / 代码地图.md 的“未推送”表述在 38cbc4b 推送后已失效（非第六批本身的错）（来源：DOCS-11）

- 位置：`docs/CODEBUDDY.md:43-44`（“第六批修复已完成、在工作树里，未提交、未推送”）、`docs/四方分工.md:60-61`（“第六批修复已完成、在工作树里，未推送，推送等 Meng 另外批准”）、`docs/代码地图.md:10`（“本地 head `bca8586`”）。
- 现象：Batch 6 已于 2026-11-15 ~11:41 CST 经 Meng 批准推送，远端 head 现为 `38cbc4b`；上述三处仍写未推送/本地 head，与现状不符，“不要 push”的禁令对象也已不存在。
- 证据：远端 head 即 38cbc4b（推送时已核对 B6-SUMMARY.md 在远端存在）。
- 修的方向：推送后同步更新三处状态（远端 head `38cbc4b`、Batch 6 已推），“不要 push”改为针对下一批。注：B6-SUMMARY 自身“不提交、不推送（推送须 Meng 另外批准）”是本批执行原则的历史记录，不用改。

## 已确认无问题（各组核实，带证据）

- **YOLO 串行化真机有效**：`yolo_onnx_service_test.dart` 实跑 27/27（含 SR2-73 真实模型并发用例）；另写 4 路并发真模型探针，4 次全部成功、无 SIGSEGV。加载共享（`loadAttempts==1`）、链抗失败毒化、加载/队列无死锁均核对无误；测试钩子生产恒 null（除服务自身外只在测试文件出现）。
- **SR2-3 临时文件与重命名**：命名冲突探针 10 万次新建 `Random()` 首抽零重复；rename 失败分支保留旧切片且不谎报、不清缓存；`evictCachedFileImage` 已移到 rename 成功后；`.tmp` 孤儿确被 `db_orphans.dart` 递归扫描覆盖；Dart `File.rename` 覆盖已存在目标是 SDK 保证（Linux `rename(2)` 原子替换；Windows 原子性未在真机验证，建议放进 Win11 复核清单）。
- **SR2-4 挂接**：跨页无串题；下游 `layer2BoxToSliceRect` 钳制安全；入库经 `confirmSplitIntoImpl` 同一路回填 `questionId`。
- **SR2-20/21/22/62**：贪心 IoU 匹配与部分匹配提示计数准确；`hasManual` 只看当前页（`'11:…'.startsWith('1:')` 为 false）；boxing 标志与警告条件一致；`_lastSplitStamp` 重抽逻辑正确（同步段内无 `await`、探针证实无空转）；SR2-26 六处调用点全部正确处理 `false`，`_saveDraft` 不再谎报。
- **SR2-5/6 本体**：主路径闭合，测试回滚验证 8/8 失败。
- **SR2-7/34 下拉兜底**：三个使用点全覆盖、复位点齐全；`_filterExamId` 与复习页 `_subjectFilter` 确无页内删除路径（路由切换 dispose State、详情页无删试卷/学科操作，已逐一核实；该防线依赖“离页即 dispose”这一导航结构，若将来改成常驻页需补兜底）。
- **月筛选 age < 30**：唯一口径点 `_filteredAll()`，周/月统一 `age >= 0 && age < limit`，列表/目录/搜索/分页都走它；`lib/` 与 `test/` 内无 `age <= 30` 残留；文案“最近 30 天”已就位；报告页“本月”自然月未动。
- **SR2-29 其余数字**：分布与弱点 Top5 都走 `_questionsInRange`（唯一题数口径点），三个核心数按 `_records` 直接算；`_causeGroups` 与 `_kpGroups` 对复查到期题的处理一致。
- **SR2-32 拼音排序**：三级比较与空名回落一致；表外汉字回退原字比较、码点恒大于拉丁字母，注释已写明不是拼音序。
- **SR2-30 缓存扫描**：递归后 cache/thumb/tmp 目录内的文件逐个按类计数、目录本身不再计 1；`_clearCache` 只删 `preview.items` 里的文件，留下的空目录下次扫描为 0、无偏差；`test/settings_page_test.dart` 在门禁跑里已有真实运行记录。
- **SR2-36 雾化**：`subjectLabelColor` 委托正确；全仓 13 处存色调用点逐一核对，除 SR3-25（B2 遗留）外全部雾化。
- **SR2-55/56 色值**：三组雾化色独立验算全符（`0xFF7CAAF2` / `0xFFE68C90` / `0xFFA799F5`，含 241.5→242 舍入）；第 13 科字面值与 31.8° 复算一致；第 14 科亦合规。
- **SR2-38**：`minSize: false` 仅三处检测来源调用点；用户手画/拖动/缩放的其余调用点全部走默认 `minSize: true`。
- **SR2-24**：逻辑与用例一致；`parentBoxId` 指向不存在的 id 时回退首个框——与第六批前行为相同，本次未改。
- **数据层**：`_failAndClean` 守卫真覆盖全部 13 个调用点；每文件兜底 try 覆盖完整；EXIF 两类失败区分正确；“成功行卡 importing”无其他出口；逐列 UPDATE 无漏列（`_toRow` 含全部 28 列）；`upsertFolder` 同事务在单连接生产拓扑下成立；SR2-16 误拒面已实证排除；`backup.json` 重名例外与两处“取最后一个”一致；SR2-19 峰值算式与 staging 模型精确一致且确如报告所说偏保守；`allCauses` 保序去重无副作用。
- **计数 778→852（净增 74）**：grep 计数 `771→845`，增量恰为 74；绝对数差由 2 处循环生成测试（+10）与 3 处注释内 `test(` 误命中（−3）解释；逐文件增量与各阶段报告一致。
- **SR2-50**：108−4=104 与 31=21+6+1+2+1 全部核实。
- **两处纠正核实**：GAPS.md 的 SDK 误判（SDK 在 `~/workspace/flutter-install/flutter/bin/`，Flutter 3.47.9）；SR-P2-6“已测”假说法（B5-P2-DATA.md 行与覆盖句均已更正）。
- **5 项口径落实**：(1) SR2-29 报告分布扣已掌握（`report_page.dart:184` 加 `!_isMastered(q)`——但与错题本口径的等价性见 SR3-2）；(2) SR2-40 紧凑行不设行号、大卡片蓝色序号圆盘保留；(3) 月筛选 `age < 30`、文案“最近 30 天”；(4) `reviewCount` 不显示（`lib/` 内仅模型/库/透传，无任何页面渲染）；(5) 三项裁决成立：SR-P2-66 雾化、SR-P2-51 12 色 + 金角（SR2-31 按 25° 阈值重算——但 15 科后兜底见 SR3-21）、SR-P2-52/55 直接通过。
- **lib/ 全量 diff 扫描**：`6448c45..38cbc4b` 的 lib/ 改动（2054 行）全部有报告对应；除报告已标出的 5 处偏离（SR2-60 `_dedupKey` 归一化、SR2-62 `_lastSplitStamp` 重抽、SR2-4 不钳制只补 `parentBoxId`、SR2-26 选“拦下”不选“放行”、SR2-22 选方案 (a) boxing 标志）外，未发现未标出的产品偏离。
- **覆盖对账**：78 项逐项对账——77 项有 B6 报告覆盖（含 SR2-49 只留档警告），唯一缺席 SR2-57（Win11 文件锁分支，有意不做）。
- **GPT 分流结论**：无法从仓库独立核实（主会话转达）；映射与本批内容一致，无矛盾。

## 已确认的遗留（B6-SUMMARY 已列，只确认、不重复编号）

- `_confirmCurrent` 自身的保存无 try（SR2-26 没点名的第 5 处）。
- SR2-3 的重命名失败分支未测（需文件系统故障注入）；进程中途被杀留 `.tmp` 孤儿文件（孤儿扫描覆盖）；另补充：Windows 上 rename 覆盖的原子性也未在真机验证，建议并入 Win11 复核清单。
- 失败行本身写不进库时，DB 任务卡在 `importing`（处方内降级，已钉测试）。
- SR2-12 同毫秒确定性覆盖需可注入时钟重构（本批范围外）。
- 旧 needBox 保留行仍靠 `_hasSplitSibling`（删拆分行后警告仍会消失——存量行的一次性处理需定）。
- SR2-19 峰值口径偏保守（最终体积 < 2GB 但峰值 > 2GB 的备份现在会被拒——Meng 如不同意需他定）。
- `_clearCache` 只删文件、留空缓存目录（下次扫描为 0，无害）。
- `toggleFavorite` / `archive` / `save` 在共享 choke 点修，未按仓库层逐列方法做（如要，另立项）；已验证具体可达场景：详情页重框刚改了 `slice_path`，错题本旧快照点收藏即把 `slice_path` 写回旧值。
- SR2-62 同毫秒场景未确定性覆盖。
- SR2-15 并发测试依赖 sqflite 事务串行化；`folders` 表无 UNIQUE 约束，若将来出现第二连接，并发同名仍可双双插成功；当前无此路径。
- SR2-16 对既有备份 fixture 的影响面——第三次全量已确认无回归，见 SR3-29（应移出遗留）。
- 历史报告里的过时措辞有意不动（历史记录）。
- `double` 封面折角：Meng 自己与 CodeBuddy 协调，Muse 不做（原决定不变）。
- 检测质量（密集排版重叠框）不在本批范围；P3(b) 孤儿目标迁移（需合并语义）仍待定。
- SR2-57：P2-11 的 Windows 文件锁分支（Linux 测不了），待 Win11 真机复核；其余沿用 2026-11-14 09:15 的验收清单。
- 测试夹具 zip 链接 2026-11-16T00:41:08Z 过期（本地副本 `~/workspace/qm2-test-fixtures.zip` 可重传）。
- 另见 SR3-28：B6-SUMMARY 遗留漏收的 7 处阶段报告级遗留。

## 协调员统一验证（2026-11-15 ~12:26 UTC，本人亲自跑）

- `flutter analyze`：**0 问题**（`No issues found!`，10.4s）。
- 全量测试（串行 `--concurrency=1`，onnxruntime `LD_LIBRARY_PATH`）：**852/852 通过**（约 5 分 35 秒，`All tests passed!`）。
- 演示库：跑全量前已备份到工作区（`~/workspace/demo-db-backup/quiz-master2.db.b6-review3-start`），跑完 md5 仍为 `8f7f9c64405dc6e484ac2bf8e5e1a807`（v1、9 道题、3 学科），已从备份恢复并再次核对 md5 一致。
- 各组单文件重跑：数据组三文件组合 76/76（×3）、五文件 103/103、`b5_p2_services` 25/25；收集组五文件 153/153；服务组 `yolo_onnx_service_test` 27/27；文档组 `flutter analyze` 全仓复跑 `No issues found!`。

## 分组报告

- `SELF-REVIEW-3-DATA.md`（DATA-1～8）
- `SELF-REVIEW-3-COLLECT.md`（COLLECT-1～7）
- `SELF-REVIEW-3-WRONGBOOK.md`（WRONGBOOK-1～5）
- `SELF-REVIEW-3-SERVICES.md`（SERVICES-1～5）
- `SELF-REVIEW-3-DOCS.md`（DOCS-1～11）
