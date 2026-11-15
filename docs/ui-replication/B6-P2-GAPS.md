# Batch 6 补漏报告：第二次自审漏派的 4 项（SR2-27 / SR2-61 / SR2-64 / SR2-73）

- 日期：2026-11-15
- 范围：仅补第二次自审（SELF-REVIEW-2.md）的 4 项漏派 P2，未碰其他项。
- 方式：只改下面列出的文件；**未提交、未推送**（推代码须 Meng 另外批准）。
- **验证状态（先读这段）：全部 4 项均“已写、未跑”。**
  - `flutter analyze` 未能执行：本机 `flutter`/`dart` 二进制不在 PATH 上（`which flutter dart` 无结果，全盘查找无 Flutter SDK），不只是任务简报里说的 clang/ninja 缺失。`flutter analyze <改动文件>` 与 `flutter test --concurrency=1 <4 个测试文件>` 各尝试一次，均以 `flutter: command not found` 失败，未产生任何分析/测试输出。
  - 替代检查（人工）：逐项重读改动区，确认语法与调用关系；用脚本粗查 6 个改动文件的括号/花括号/方括号配平，均为 0 差值。**这不能代替 `flutter analyze` 与实跑**，工具链恢复后必须由总协调补跑（见每项末尾“补跑重点”）。
  - 测试全部按串行（`--concurrency=1`）设计；`testWidgets` 体内无异步文件 IO（SR2-61 的播种是 sqflite_ffi 内存库调用，同步 FFI 包一层 Future，微任务完成；SR2-73 的图片文件在普通 `test()` 内生成）。

## SR2-27（P2，代码）— `boxesForPageImageFromImpl` 补 ORDER BY

- 改动：`lib/data/db_collect.dart:221-247`（`boxesForPageImageFromImpl`）。
  - 框查询补 `orderBy: 'page ASC, id ASC'`（:244），与同文件 :199 的 `boxesForTask` 对齐。
  - 题 id 查询补 `orderBy: 'id ASC'`（:232）。注意：转交项原文是“两次 `db.query` 均补 `ORDER BY page ASC, id ASC`”，但 `questions` 表没有 `page` 列，`page ASC` 在此查询上不合法；改为按 `id` 排。返回行序由框查询的 ORDER BY 决定，题 id 列表的顺序只影响 `IN (...)` 的构造，不影响最终行序。
  - 注释已写明此取舍；`lib/widgets/widgets.dart:84-88` 的 `realRegionRects` 注释本来就写“行序本身见 boxesForPageImageFromImpl 的 ORDER BY”，本次修法使代码与该注释一致，无需另改文档。
- 测试：`test/b5_p2_data_test.dart:721` 新增 group `SR2-27 boxesForPageImageFrom 按页与 id 排序`，1 个用例。
  - 两题同页、题行倒序插入；4 个框故意按非排序顺序插入（rowid 序 ≠ page/id 序，旧实现会返回乱序）；断言返回 `['b-p1-a', 'b-p1-b', 'b-p2-a', 'b-p2-b']`（同页多框按 id 序）。
  - 另断言他页题的框不混入、无题页图返回空。沿用本文件既有模式（`openTestDb()` 内存库 + `insertQuestion`/`_boxRow` 辅助函数），未发明新脚手架。
- 补跑重点：单跑 `flutter test --concurrency=1 test/b5_p2_data_test.dart`，确认 SR2-27 用例通过；可临时去掉 ORDER BY 反证用例变红（插入序与期望序不同，旧实现应失败），再恢复。

## SR2-61（P2，测试）— 真实仓储泵首页的 widget 用例

- 结论：**真实仓储泵首页可行，已写出用例**，未记为已知边界。
- 改动：
  - `test/b5_p1_1_subject_counts_test.dart:222-258` 新增 `testWidgets('真实仓储泵首页：焦点卡待解决 2 道 · 复查 2 道（SR2-61）')`。
  - `test/home_page_test.dart:105-110`：`pumpHome` 的 `repo` 参数由 `FakeRepo?` 放宽为 `QuestionRepository?`（FakeRepo 是其子类，现有调用不受影响；`HomePage.repo` 本来就是 `QuestionRepository` 类型）。这是本项唯一的共享辅助改动。
- 用例做法（沿用 test 里既有模式，未发明新脚手架）：
  - `AppDatabase.openForTest()` + `AppDatabase.useDatabaseForTest(db)`（`test/s8b3_startup_test.dart` 同款；只建表不播种），`addTearDown(() async => AppDatabase.resetForTest())` 复位单例。
  - 播种全用仓库写方法：`repo.saveSubject`（`Subject.all` 三科）、`repo.save(q)`、`repo.saveCauseRecord(r)`，种子即本文件既有的 `_scenario()`（数学 7 题 + 英语 1 题 + 错因记录）。`repo.save` 经 `upsertQuestionIntoImpl` 整行 INSERT 写 `review_joined`/`is_organized`；`saveCauseRecord` 在行不存在时整行 INSERT（含 `recheck_date`），播种口径已核对过 `lib/data/db_codec.dart:59`（`_toRow`）与 `lib/data/db_questions.dart:357`（`upsertCauseRecord`）。
  - 先断言仓储层数（`dueToday` = `{q1, q2, q3, q8}`、`homeRevCounts` = `{math: 3, english: 1, politics: 0}`，与 FakeRepo 手填数一致），再 `pumpHome` 断言焦点卡文案 `4 道要复习` 与 `待解决 2 道 · 复查 2 道`——仓储算错与首页渲染错能分清。`_recent` 为 null 时首页有处理（`home_page.dart:233`），`pendingOrganizeBySubject` 在空任务表上返回 0，不影响焦点卡。
  - `testWidgets` 体内无异步文件 IO：播种与 `_load` 的库调用都是 sqflite_ffi 同步 FFI 包一层 Future（微任务完成）。
- 补跑重点：单跑 `flutter test --concurrency=1 test/b5_p1_1_subject_counts_test.dart`；重点看新用例是否在 FakeAsync 下正常完成播种与 `pumpAndSettle`（若播种 await 挂起，说明 ffi 调用在该环境下不是纯微任务，需把播种移到 `setUpAll` 真实 zone 或改回分层测试并记为已知边界——写用例时已按微任务完成的前提设计，未实测）。

## SR2-64（P2，测试）— 复查日恰好是今天的边界

- 改动：`test/b5_p1_1_subject_counts_test.dart:113-137`，在既有 `reviewBucketOf`/`isReviewDue` 用例（`reviewBucketOf：四桶互斥，混合错因题只落待解决`）开头补 4 个断言，未动 `_scenario()`（避免改动既有计数与焦点卡文案）。
  - `recheckDate` = 今天零点（`DateTime(now.year, now.month, now.day)`）：`reviewBucketOf` = `recheck`，`isReviewDue` = true。
  - `recheckDate` = 当前时刻（`DateTime.now()`）：同上。
- 依据：`lib/models/models.dart:139-146` 的 `isRecheckDue` 按日期比较（`!d.isAfter(today)`），当天任意时刻都算到期；这是“待复查”与“已解决”的分界点。实现未动，只补测试。
- 补跑重点：与 SR2-61 同文件，一并单跑 `test/b5_p1_1_subject_counts_test.dart`；确认 4 个新断言通过（尤其“当前时刻”不断言为 `solved`）。

## SR2-73（P2，测试）— 并发检测共用 `_loadFuture`

- 生产改动（最小测试观测点，生产行为不变）：`lib/services/yolo_onnx_service.dart`。
  - `:1` 加 `import 'dart:async';`；`:134-150` 加静态计数 `_loadAttempts`、只读 getter `loadAttemptsForTest`、并发屏障 `loadGateForTest`（`@visibleForTesting`，生产恒为 null）。
  - `:225-231` `_loadOnce()` 入口先 `_loadAttempts++` 再等 gate（若已设置）；`:110-112` `resetLoadStateForTest()` 一并复位计数与屏障。
  - 为什么要加屏障：无原生库时加载在 `OrtEnv.instance.init()` 处同步失败（`DynamicLibrary.open('libonnxruntime.so.1.15.1')` 抛错被 `_loadOnce` 的 try 接住），不设屏障两次检测几乎不可能在同一次加载内重叠，计数断言会随图片解码时序抖动。屏障只在测试里设置，`_loadOnce` 内 `gate == null` 时零开销。沿用本文件已有的 `resetLoadStateForTest` 测试缝先例，未改加载逻辑本身。
- 测试：`test/yolo_onnx_service_test.dart`。
  - `:8` 加 `import 'dart:async';`；`:28-60` 加辅助函数 `_whitePagePng`（100×100 纯白 PNG，与冒烟组同款画法抽出）与 `_waitFor`（轮询等条件，默认 5 秒超时）。
  - `:473` 新增 group `SR2-73 并发检测共用 _loadFuture`，2 个用例（均为普通 `test()`，图片文件在 `test()` 内生成，不在 `testWidgets` 内）：
    1. **模型缺失路径**（`does-not-exist.onnx`，两个不同实例——`_loadFuture` 是静态的，跨实例也应共用）：设 gate → 发第一次检测 → 轮询到 `loadAttemptsForTest == 1`（确认第一次加载已停在屏障处）→ 发第二次检测 → 等 500ms（给第二次解码 + 到达 `_ensureLoaded` 留余量；加载仍被屏障按住，晚到也会加入同一个 future）→ 放行 gate → 断言两次结果都是 fallback（`usedFallback` 真、`error` 含“手动框选”）且 `loadAttemptsForTest == 1`。**该用例无原生库也可全程断言，不跳过。**
    2. **真实模型路径**（默认模型 asset，两个实例）：同款屏障流程；共享断言（`loadAttemptsForTest == 1`）与原生库无关，先断言；随后 `!hasRealModel` 时先断言两次结果是确定的 fallback 行为，再 `markTestSkipped` 并写明原因（`:553`，含 `hasRealModel=false` 与“共享加载已由计数断言覆盖”）；有原生库时断言两次 `usedFallback` 均为 false 且双方 `lastDetectStats` 非空。finally 里先放行 gate 再删临时目录、复位加载状态，避免失败时留下挂起的加载。
- 补跑重点（工具链恢复后，`flutter test --concurrency=1 test/yolo_onnx_service_test.dart`）：
  - 用例 1 必须通过且不跳过（它是 SR2-73 的核心断言在无原生库环境下的兑现）。
  - 用例 2 在本机（无原生库）应走到 `markTestSkipped`，且跳过前 fallback 断言与计数断言已执行——在 expanded 日志里确认跳过原因文本出现；有原生库的环境应跑通成功路径（两次 `usedFallback` false）。
  - 另注意：500ms 等待是“等第二次检测到达 `_ensureLoaded`”的经验余量（100×100 PNG 解码毫秒级）；若该环境解码极慢导致计数为 2 而失败，优先把等待改长，不要改生产屏障逻辑。

## 未动项与遗留问题

- 未碰 SR2-27/61/64/73 以外的任何项；未提交、未推送。
- 工作树内另有其他执行员未提交的 Batch 6 改动，本报告只覆盖上述 6 个文件的本次补漏部分。
- 遗留（需总协调）：
  1. **工具链缺失超出简报所述**：简报称“clang/ninja 不在，`flutter analyze` 为准”，实际本机连 `flutter`/`dart` 二进制都没有，`flutter analyze` 与 `flutter test` 均无法执行一次有效运行。4 项全部“已写、未跑”，`analyze 0 问题` 未验证；恢复工具链后须先跑 `flutter analyze`（6 个改动文件）再按上文逐项补跑测试。
  2. SR2-61 的真实仓储 widget 用例依赖“sqflite_ffi 内存库调用在 `testWidgets` 的 FakeAsync 下经微任务完成”这一前提（已核对 `sqflite_common_ffi` 的 handler 是 Dart 侧同步执行包 Future），未实测；补跑时若播种挂起，按报告内写的退路处理。
  3. SR2-73 的 500ms 等待是经验余量，见上文。
  4. SR2-27 的题查询 ORDER BY 取 `id ASC` 而非转交项字面的 `page ASC, id ASC`（`questions` 表无 `page` 列），已在代码注释与本报告写明；若协调员要求字面一致，需另议（SQL 上不可行）。
