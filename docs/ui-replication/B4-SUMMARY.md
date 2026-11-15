# 第四批 God 类拆分汇总（B4-SUMMARY）

- 时间：2026-11-14
- 范围：Meng 批准（“马上拆就行”），后追加 `wrongbook_page.dart`（Meng 22:06 追加，3718 行、全项目最大）
- 分支：`ui-replication`；工作树 `~/workspace/quiz-master2-UI`
- 状态：**全部完成，未推代码**（按纪律：Batch 1/2/3 + spine-fix + Batch 4 改动在最终自审前不 push，Meng 看完自审汇总再决定）
- 性质：**纯重构**——不改行为、不修 bug、不加功能；不碰等 Meng 决定的两件事（.gitignore 是否忽略 38MB 模型文件；红色无框警告范围是否收窄）；不修第三批遗留问题

## 基线（协调员开工前验证）

- `flutter analyze`：0 问题
- 全量测试：**628/628 通过**
- 演示库：`~/.local/share/quiz-master2/quiz-master2.db` md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`（v1、9 题、3 学科）；备份 `~/workspace/demo-db-backup/quiz-master2.db.b4-start`

## 逐项结果

### 1. `lib/data/database.dart`（报告 B4-DATABASE.md）

- 3191 行（约 119KB）→ **541 行入口 + 10 个 part 文件**，共 2964 行。
- 手法：`database.dart` 声明 `part 'db_*.dart';`，新文件为同一库的 `part of`，共享库私有成员。56 个公开静态方法 → 顶层 `<name>Impl` 函数 + 类内一行同签名静态转发；32 个私有静态方法/字段 → 同名顶层函数/变量；67 个实例方法 → 各文件的 `extension … on AppDatabase`。`repository.dart`、各页面、全部测试文件零改动。
- 新文件：`db_paths.dart`（137 行，路径/数据目录）、`db_schema.dart`（279 行，建库 DDL/老库删除/播种）、`db_storage.dart`（345 行，目录迁移）、`db_codec.dart`（250 行，JSON 编解码与行映射，任务清单外新增，四处共用故单列收口）、`db_questions.dart`（284 行，题目/错因/复习状态）、`db_catalog.dart`（494 行，学科/文件夹/标签/试卷/知识点）、`db_collect.dart`（547 行，收集任务/question_boxes/文件级联删除）、`db_orphans.dart`（123 行，孤儿扫描清理）、`db_settings.dart`（178 行，设置/最近任务/演示数据）、`db_backup.dart`（327 行，备份与恢复 JSON/zip）。
- 接口：**无调整**。脚本核对：新增成员 0 个，56 个转发签名与原声明逐字一致。
- 验证：`flutter analyze`（`lib/data/` 与全量）0 问题；相关测试分 5 批 **507 个全部通过**（未跑全量，留协调员统一跑）；`dart format` 后复跑 60 个关键测试再过一遍；演示库 md5 未变。
- 拆前备份：`~/workspace/demo-db-backup/database-before-b4/database.dart.before-b4`（拆分前原文件全文，含 Batch 1/2/3 未提交改动）与 `quiz-master2.db.b4-db-start`；验收通过后可删。

### 2. `lib/modules/collect/collect_page.dart`（报告 B4-COLLECT.md）

- 3349 行（约 129KB）→ **3 个文件，共 3381 行**（+32 行全是新文件头注释、import 与 re-export 行，移动的代码本体一字未改）。
- 新文件：`collect_page.dart` 1316 行（`CollectPage` + 任务列表/导入/拆题确认/删除/任务行/状态 pill/筛选）；`box_editor.dart` 2021 行（`BoxEditorMode`、`BoxEditorResult`、`showBoxEditorDialog`、修框编辑器逐字移出）；`collect_widgets.dart` 44 行（`_DashedDropPainter` → 公开的 `DashedDropPainter`，画法未动）。
- 除整块移动外仅 4 处改动：删拆分后无用的 3 个 import；新增 import + `export 'box_editor.dart'`；两处 `_DashedDropPainter(` 调用点同步改名；`box_editor.dart` import 按需取子集并补 `page_image_pipeline.dart`（`rotateBoxToRotatedPage`）、删不用的 `widgets.dart` import。
- 接口：**无调整**。`BoxEditorMode` / `BoxEditorResult` / `showBoxEditorDialog` 仍可从 `collect_page.dart` import（re-export）；`app.dart` 与详情页一字未改；全部测试文件未改。`_CollectPageState` 的任务行/筛选等方法未抽 widget（与 state 深度耦合，抽出需重构签名，风险大于收益）。
- 验证：`flutter analyze` 0 问题（首次曾报 3 error + 4 warning，均为 import 归属问题，已修正）；相关测试 **70/70**（collect 43/43、pdf_collect 1/1、detail 26/26）；演示库 md5 未变，备份 `quiz-master2.db.b4-collect-start`。

### 3. `lib/modules/wrongbook/wrongbook_page.dart`（报告 B4-WRONGBOOK.md，Meng 追加）

- 3718 行（约 129KB）→ **6 个文件，共 3746 行**（+28 行全为 `part` 声明、extension 包裹、文件头注释与 `_update` 转发，无新增行为代码）。（SR-P2-91 修正：原报告误写 3740 行 / +22 行，已按拆分完成时实测更正；行数为 B4 完成时口径。）
- 手法：`part` / `part of` + 同库 extension（Dart 无 partial class，同库可访问私有成员，对外接口零调整）。拆分脚本逐段拼回校验与原文逐行一致后才落盘。
- 新文件：`wrongbook_page.dart` 1147 行（页面态与业务逻辑，part 宿主）；`wrongbook_shelf.dart` 496 行（书架 + `_CoverReviewButton`）；`wrongbook_directory.dart` 601 行（目录页）；`wrongbook_list.dart` 1142 行（书内列表）；`wrongbook_cover.dart` 278 行（6 个 CustomPainter 逐字：折角 34×34、书脊负偏移、虚线非对称圆角等）；`wrongbook_widgets.dart` 82 行（`_QmPaperButton` + `_PaperStarButton` 逐字）。
- 唯一非逐字改动：extension 里调 `setState` 触发 54 项 `invalid_use_of_protected_member`，故在 State 内新增等价转发 `void _update(VoidCallback fn) => setState(fn);`，三处 extension 文件 54 处 `setState((` 机械替换为 `_update((`（6+20+28）。语义行为完全相同，未用 `// ignore`。
- 接口：**无调整**。`app.dart` 的 import 不用改；无新增导出符号。
- 验证：`flutter analyze`（模块 + 全量）0 问题；相关测试 6 文件 **76/76 全绿**（`wrongbook_page_test.dart` 43 项含书脊回归测试）；演示库 md5 未变，备份 `quiz-master2.db.b4-wrongbook-start`。
- 说明：该工人任务开始时误跑了一次只读的 `git status` + `git branch`（未改动任何状态），此后全程未再用 git 命令。

## 协调员最终统一验证

- `flutter analyze` 全量：**No issues found（0 问题）**
- 全量测试：**628/628，All tests passed**（`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`）
- Linux Release 构建：**成功**（`flutter build linux --release` → `✓ Built build/linux/x64/release/bundle/quiz_master2`）
- 演示库：跑完 md5 仍为 `8f7f9c64405dc6e484ac2bf8e5e1a807`（v1、9 题、3 学科），未改动

## 改动文件总览

- 改：`lib/data/database.dart`（3191 → 541 行）、`lib/modules/collect/collect_page.dart`（3349 → 1316 行）、`lib/modules/wrongbook/wrongbook_page.dart`（3718 → 1147 行）
- 新：`lib/data/db_*.dart`（10 个）、`lib/modules/collect/box_editor.dart`、`collect_widgets.dart`、`lib/modules/wrongbook/wrongbook_*.dart`（5 个）
- 报告：`docs/ui-replication/B4-DATABASE.md`、`B4-COLLECT.md`、`B4-WRONGBOOK.md`、本文档 `B4-SUMMARY.md`
- 未改：任何测试文件、任何调用方（`app.dart`、详情页等）、`.gitignore`、红色无框警告相关代码；未执行任何 git 提交/推送

## 遗留问题

- 无阻塞遗留。三处仍较大的文件如需继续瘦身，均需另立任务（传参重构，超出本次纯搬移范围）：
  - `lib/modules/wrongbook/wrongbook_list.dart`（1142 行）：可按筛选面板/卡片/分页拆子 widget。
  - `lib/modules/collect/collect_page.dart`（1316 行，`_CollectPageState` 约 1230 行）：可拆任务行/筛选等 state 方法。
  - `lib/data/db_collect.dart`（547 行）、`db_catalog.dart`（494 行）为数据层内最大两块，但已是单一职责内聚文件。
- 下一步：全部修复批次（Batch 1/2/3/4 + spine-fix）已完成，按 Meng 的指令进入**最终自审**（Muse 通读代码找问题并汇总汇报），自审汇总后再由 Meng 决定是否推送。
