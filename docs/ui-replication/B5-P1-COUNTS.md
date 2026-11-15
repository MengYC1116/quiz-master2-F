# 第五批第三阶段 P1 口径类修复报告（B5-P1-COUNTS）

- 时间：2026-11-14
- 范围：最终自审 P1 口径类 6 项（SR-P1-1、SR-P1-9、SR-P1-10、SR-P1-11、SR-P1-12、SR-P1-13、SR-P1-15）
- 分支：`ui-replication`；工作树 `~/workspace/quiz-master2-UI`
- 状态：**全部完成，未推代码**

## 逐项结果

### SR-P1-1 错题本封面三数与首页口径统一

- 修法（已定口径）：封面三数沿用首页互斥拆分。`lib/data/repository.dart` 新增 `ReviewBucket` 枚举（pending / recheck / solved / none）与静态方法 `reviewBucketOf()`、`isReviewDue()`：有未解决错因 → 只计“要复习”；全部已解决且到复查时间 → 只计“待复查”；全部已解决且未到复查时间 → 只计第三项“已解决”；无记录 → 都不计。要复习 + 待复查 = 要复习总数。`dueToday` 改用 `isReviewDue`（行为不变）；`subjectCounts` 两个独立 `if` 改为 `switch (reviewBucketOf(rs))`，注释重写（删“可同时计入”，写明互斥与 `solved` 语义：已加入复习、已整理、全部错因已解决且无一条到复查时间的题数；已掌握但到复查时间的题计入“待复查”）。首页焦点卡拆分改走 `QuestionRepository.reviewBucketOf`，文件头口径注释同步更新。
- 测试：新 `test/b5_p1_1_subject_counts_test.dart` 4/4（待解决/纯复查/混合/已解决/无记录/未整理/未加入/英语纯复查题；断言封面三数、两数之和 = 首页各科数、`dueToday` 题集、焦点卡文案）；相关既有测试 78/78（`p0b1_archived_counts_test`、`s8b2_subject_sync_supplement_test`、`home_page_test`、`wrongbook_page_test`）。
- 报告：`docs/ui-replication/B5-P1-1.md`。

### SR-P1-10 + SR-P1-11 学习报告计数口径

- SR-P1-10：薄弱 Top5 改按题 id 计数。`_WeakGroup` 新增 `questionIds: Set<String>`，`count` 改为 `questionIds.length`；`_causeGroups` / `_kpGroups` 两处去重改为 `if (g.questionIds.add(q.id)) g.titles.add(q.title)`，`titles` 只作展示拼接。同名不同题各算 1 道。
- SR-P1-11：弱点 Top5 与学科分布排除未整理题、已归档题。`_questionsInRange` 增加 `q.isOrganized && !q.isArchived` 过滤，与错题本 `_filteredAll` / `_folderCount` 的默认收录口径一致；页头口径注释同步更新。三个核心数按错因记录计，不受影响，未动（既有设计 S8 B1，不在本项范围）。
- 测试：`test/report_page_test.dart` 25/25（含新增 2 项）。
- 报告：`docs/ui-replication/B5-P1-10-11.md`。

### SR-P1-9 + SR-P1-13 + SR-P1-12（复习页与错题本）

- SR-P1-9：复习“上次自查”`history.last` → `history.first`（数据源 `reviewHistory()` 是 `reviewed_at DESC`，首条即最新）。
- SR-P1-13：`_skipCurrent` 里跳过块内最后一个错因时直接进 `_Phase.redo`（复用 `_nextFromRemedy` 的收尾判断），只有块中部跳过才停在当前 `_ci`。`_ci` 仍钳回块内末位——`_buildSession` 无条件取 `_currentCause` 查记录，越界会抛 `RangeError`。
- SR-P1-12：与 `_viewModeInitialized` 同款：错题本加 `_sortInitialized` / `_pageSizeInitialized`，复习加 `_pageSizeInitialized`，只首次 `_load()` 取设置默认值；`_defaultSort` 仍每次更新，“重置”行为不动。
- 测试：`review_page_test.dart` + `wrongbook_page_test.dart` 77/77（含新增 5 项）；`b2_leftover_wrongbook_view_test.dart` 6/6（确认 `_load` 标志改动未破坏既有视图保留行为）。中间出现过 1 次新测试自身失败（初版 P1-13 测试误用步骤指示条 pill 文案断言所在步骤，已改用重做步独有文案断言，产品代码无改动）。
- 报告：`docs/ui-replication/B5-P1-9-12-13.md`。

### SR-P1-15 CompactSliceThumb 加 errorBuilder

- 修法：`CompactSliceThumb.build` 把原有内联失败占位抽成局部变量 `failedPlaceholder`，`failed`/`missingRealImage` 分支与新增的 `errorBuilder` 共用，不另造样式。口径说明：64×48 的缩略图放不下 `QuestionSlice._missingImagePlaceholder` 的完整版（34px 图标 + “学科 · 题型” + 长文案），复用的是其紧凑尺寸同款——学科图标 + “图片缺失”/“加载失败”文案；解码失败时文案为“加载失败”，与原 `failed` 分支一致。
- 测试：`test/b3_p11_layer2_downgrade_test.dart` 8/8（原有 6 项 + 新增 2 项：损坏切片显示“加载失败”+ 学科图标且无异常；有效切片正常显示图片）；`p2_main_chain_test.dart` 13/13。过程说明：初版回归测试误写 `expect(find.byType(Image), findsNothing)`，失败后查明 `errorBuilder` 是在 `Image` 内部渲染占位、`Image` widget 本身仍在树上，已去掉该断言并在测试注释中说明。
- 报告：`docs/ui-replication/B5-P1-15.md`。

## 阶段统一验证（协调员亲自跑）

- `flutter analyze`：**No issues found（0 问题）**。
- 全量测试：**674/674 通过，0 失败**（P1-DATA 结束 661 + 本阶段新增 13：P1-1 的 4 个 + P1-10/11 的 2 个 + P1-9/12/13 的 5 个 + P1-15 的 2 个），`LD_LIBRARY_PATH` 含 onnxruntime-1.4.1。
- Linux Release 构建：**成功**（`✓ Built build/linux/x64/release/bundle/quiz_master2`）。
- 演示库：跑完 md5 仍为 `8f7f9c64405dc6e484ac2bf8e5e1a807`（v1、9 题、3 学科），未被改写。
- 未提交、未推代码；未动 `assets/models/` 模型文件与 `test/fixtures/`。

## 遗留问题

- `box_editor.dart:1352` 的页图 `Image.file` 仍无 `errorBuilder`（自审称“顺带补即可”）；该处有 `_pageImageFailed` 门控（先行解码判断），风险低，本次按任务范围未动，如需补与 SR-P1-15 同款做法即可。
- SR-P2-58（“重置”固定回时间新→旧）是 P2 项，本次未动，属第五阶段范围。
