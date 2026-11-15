# B3 文档更新（Batch 3 最后一项）

工人：b3-docs。工作树 `~/workspace/quiz-master2-UI`，分支 `ui-replication`。
未做 git 操作（不 commit、不 push、不 reset、不 checkout）；
未碰 `assets/models/`、未碰 `test/fixtures/` 二进制；
只改了以下 4 份文档 + 本报告，未改任何 `lib/` 与 `test/` 代码；
未跑测试、未跑 analyze、未备份演示库。
文中不写全量测试通过数（最终验证还没跑）。

## 1. 每份文档改了什么

### `docs/代码地图.md`（主要修正点）

- 卷首说明更新为 2026-11-14、Batch 3 后的状态；删掉“R11 §8 修复正在落地 / B 组决定正在实现”的过期提示。
- §1 依赖：3 个 → 全部 6 个（`sqflite_common_ffi ^2.3.6`、`path ^1.9.1`、`file_picker ^8.0.0`、`onnxruntime ^1.4.1`、`pdfrx_engine ^0.9.2`，dev `flutter_lints ^5.0.0`）；加跑测试前备份演示库的提醒。
- §2 目录表：`lib/` 约 2.2 万行 → 约 2.96 万行；补齐 `pdf_render_service` / `page_image_pipeline` / `recheck_reminder` / `zip_archive` 四行；`yolo_onnx_service` 与 `import_service`（真实复制进度）改对；`demo_data` 注明演示题只定义、不预置；`assets/models/` 改为“第 1 层真模型在工作树里、由 Meng 自己放、不进仓库”。
- §3 表结构：12 张表 version 1 → **13 张表、schemaVersion 2**（新增 `question_boxes` 行，含 3 个索引与每题唯一 layer-1 框索引）；讲清 `schemaVersion` 与 sqflite `version` / `user_version` 的区别；建库流程改为 `openAt` + `deleteLegacyDatabaseIfPresent`（老库删掉重建，无迁移、无 `onUpgrade`）；多值字段逗号分隔 → **JSON 字符串数组**（`encodeStringList` / `decodeStringList`）；新增“演示库是 v1”小节与“第三批后的关键行为”小节（路径删除安全、删除确认统一模态弹窗、测试隔离钩子 `openForTest` / `resetForTest` / `testDataDirectory` / `useDatabaseForTest`、P1-1 / P1-2 / 叠加层真实框坐标的指向）。
- §3 模型：`QuestionBox` 加第 2 层暂缓说明；`questions` 表行补切片字段。
- §4 收集中心：导入进度模拟 → 真实复制进度（旧 `_simulateImport` 已删）；修框编辑器加单框不旋转（圆柄已去掉，整页旋转保留）、右键拖动任何位置画新框、框初始检测来自第 1 层真模型；确认修框加 P1-2 未框页保留（确认前弹框提示页数、只拆有框页、任务行下红色警告）；删失败任务“不用二次确认” → 一律弹模态确认框。
- §4 整理工作台：修框切片段改为真实题只剩“整题框切片”一张卡（P1-1）；题图放大浮层加叠加层真实 Layer-2 框坐标说明（`realRegionRects`，无框回退示意框，是否显示仍由 `regionsOfQuestion` 决定）。
- §4 设置：备份“只导 JSON、只含 8 张表” → 含文件的 zip（`backup.json` + `imports/` + `slices/`），13 张表全在 `backupTables` 清单里；首页红色横幅“§8 修复正在接上线” → 已接上线（`app.dart` 读 `backupFailed` 标志）。
- §6 数据库加字段：原“`version: 1` 改成 2 + 新写 `onUpgrade`”流程全部重写为 v2 不迁移流程（改 `createTables` + 改 `schemaVersion`，旧库下次打开删掉重建；改前先备份）。
- §8：Schema 小节 12 张表 version 1 → 13 张表 schemaVersion 2；“YOLO 占位实现别当真”整节重写为真模型（模型路径、`hasRealModel` 含义、回退框、推理链路、第 2 层再接入点、两模型同名须分文件夹）。

### `docs/CODEBUDDY.md`（主要修正点）

- 决策记录 D-00～D-22 → D-00～D-23（以 `docs/decision-log.md` 实际为准）。
- “当前状态”整节重写（2026-11-13 → 2026-11-14）：删掉“YOLO 还是占位实现（`hasRealModel` 为 false）、模型在 Meng 的 Google Drive 里还没接入、R11 §8 A/B 组修复正在进行、head `0d9d15d`”；改为第 1 层真模型（模型路径、约 38MB、Meng 自己放、不进仓库）、第 2 层暂缓（`intraEnabled = false` + 再接入点）、Schema v2 / 13 张表 / 无迁移、演示库是 v1、测试隔离钩子、Batch 1/2/3 改动未提交未推送（最终自审前不 push，push 需 Meng 批准；不 commit/reset/checkout）。

### `README.md`（主要修正点）

- 结构树第 54 行附近：`database.dart SQLite（v2 全新 schema，version 1）` → `schemaVersion 2，13 张表`。
- `demo_data.dart` 行：只写“演示数据：数学/英语/政治各 3 道大学题” → 注明是定义（`demoQuestions()` 共 9 道）+ 演示试卷/知识点树，新库建库时不预置演示题（§6 第 1 条）。
- 其余已在树上未提交改动里改对（依赖、YOLO 第 1 层真模型、服务列表），本次核对后未再动。

### `docs/quiz-master2-mo-kuai-bian-jie-hua-fen.md`（主要修正点）

- 复习改为已确认：§3 表格复习行“未确认”→“已确认”；§5.2 整节移为 **§4.5**（内容一字未动，仍在“已确认模块”章内），§5.3/§5.4 顺延为 §5.2/§5.3；卷首、§3 说明、§5 引言、§8 末句的计数同步为“已确认 5 页、未确认 3 页（4 行）”；§4.3 的“（见 5.2）”改为“（见 4.5）”。
- §4.2 收集中心：导入校验“失败任务删除不需要二次确认”→ 删除任务一律弹模态确认框；修框编辑器“拖角缩放与旋转”→ 单框不旋转（圆柄已去掉）、右键拖动任何位置画新框、左键拖动移框、整页旋转保留；两层框加“第 1 层由 YOLO 真模型检测、第 2 层只有手画（自动检测暂缓，`intraEnabled = false`），手动二层框照常存库”；确认校验加 P1-2 未框页保留（确认前弹框提示页数、只拆有框页、任务行下红色警告）。
- §4.3 整理工作台：整题图查看“放大状态下二层框高亮保持可见”→ 只对演示题/老题显示，有真实 Layer-2 框按真实框坐标画、无框回退示意框；“只保存整题图与二层切片图”→ 只保存整题图，二层切片暂缓（P1-1），手动二层框不删、暂不接线。
- §5.1 题目详情：完整呈现“整题图与二层切片”→ 整题图（真实题只显示整题切片，不标二层框；二层切片暂缓）。

## 2. 核实事实的依据（以哪处代码为准）

- **表数量与表名**：`lib/data/database.dart` 的 `createTables`（L755 起），13 个 `CREATE TABLE`：subjects、questions、folders、tags、exams、knowledge_points、collect_tasks、cause_records、review_state、review_history、recent_tasks、settings、question_boxes；另有 3 个索引 + 1 个唯一索引。
- **Schema 版本**：`lib/data/database.dart`：`schemaVersion = 2`（L91）；`openAt` 用 `version: schemaVersion` 打开（L693），`_onCreate` = `createTables` + `_seed`（L747）；`_seed` 只写学科/文件夹/标签/演示试卷/演示知识点树 + `settings` 的 `schemaVersion = '2'`，不写演示题（L932–934 注释与 §6 第 1 条一致）；`backupTables` 13 张表（L2857）。
- **依赖版本**：`pubspec.yaml` 实际内容：`sqflite_common_ffi ^2.3.6`、`path ^1.9.1`、`file_picker ^8.0.0`、`onnxruntime ^1.4.1`、`pdfrx_engine ^0.9.2`，dev `flutter_lints ^5.0.0`；Flutter 3.47.9 / Dart 3.13.7 锁定。
- **YOLO 现状**：`lib/services/yolo_onnx_service.dart`：模型路径 `assets/models/question/yolo11s-question-v1.onnx`（L50），`hasRealModel => _loadOk`（L99），`intraEnabled = false`（L67），第 2 层再接入点见该文件 L37–38、L258–260 注释。模型文件在工作树 `assets/models/question/yolo11s-question-v1.onnx`（38,432,570 字节），`git ls-files assets/models/` 只有 README，未提交。
- **演示库是 v1**：2026-11-14 只读实测 `~/.local/share/quiz-master2/quiz-master2.db`：`PRAGMA user_version = 1`，12 张表，无 `question_boxes` 表，`settings` 无 `schemaVersion` 行，9 道题全是演示题（`is_demo = 1`）。`demoQuestions()` 在 `lib/data/demo_data.dart` 定义（9 道），除定义外全仓无生产调用方。
- **测试隔离钩子**：`lib/data/database.dart` L104–116（`testDataDirectory` / `testMarkerDirectory`）、L215（`openForTest`）、L233（`resetForTest`）；隔离写法以 `docs/ui-replication/B3-P02-TEST-ISOLATION.md` 为准。
- **路径删除安全**：`lib/data/database.dart` L148（`resolveDataPath` 默认拒绝对路径）、L2152（删文件只认 `slices/`）、L2195（删任务目录校验 taskId）、`_openDb` fallback 收窄（L636 起）；以 `docs/ui-replication/B3-P01-PATH-SAFETY.md` 为准。
- **删除确认统一模态弹窗**：以 `docs/ui-replication/B3-DELETE-CONFIRM.md` 审计清单（20 行）为准；整理队列层 `OverlayEntry` + `ModalBarrier` + `AlertDialog` 的例外见该报告“层级问题”。
- **P1-1 / P1-2 / 叠加层**：以 `docs/ui-replication/B3-P11-LAYER2-DOWNGRADE.md`、`B3-P12-UNBOXED-PAGES.md`、`B3-OVERLAY-LAYER2.md` 为准，并核对了 `lib/widgets/widgets.dart` 的 `regionsOfQuestion` / `layer2BoxToSliceRect` / `realRegionRects` / `QuestionRegionOverlays` 与 `lib/modules/organize/organize_page.dart` 的 `_loadRealBoxes` / `_realRegionRects` 接线。
- **导入进度真实化**：`lib/services/import_service.dart` L168 注释“真实进度（替换旧 `_simulateImport` 假进度）”，`lib/modules/collect/collect_page.dart` 已无 `_simulateImport`。
- **备份失败横幅已接线**：`lib/app.dart` L80、L110–122、L417、L430（读 `backupFailed` 标志传 `showBackupError`）；`lib/modules/settings/settings_page.dart` L242。
- **分支与 head**：`git branch` 为 `ui-replication`，`git log -1` 为 `bca8586`；Batch 1/2/3 改动未提交（`git status` 中 4 份文档之外的 `lib/` / `test/` 改动均为本次任务前已有的未提交改动，本次未碰）。

## 3. 遗留问题

1. **模型文件未被 `.gitignore` 忽略**：`git check-ignore assets/models/question/yolo11s-question-v1.onnx` 返回 exit 1（未忽略），`.gitignore` 里没有 `assets/models` 相关行；文件目前只是未提交（`?? assets/models/question/`），但一次不小心的 `git add .` 就会把它（38MB）收进仓库。文档里已按任务要求写“模型由 Meng 自己放、不进仓库”，但忽略规则本身还没补——这不是文档改动，需要另行决定是否在 `.gitignore` 里加一行（本次按“只改 4 份文档”纪律未动）。
2. **边界文档 §4.2/§4.3/§5.1 仍有本次范围外的旧描述**：如 §4.3 整理表单字段顺序仍写“学科、文件夹、试卷……”开头（代码地图已按 2026-11-12 决定写“无学科字段、文件夹是独立分段”），§4.2 “任务超过 3 条才出现滚动条”等。任务只要求修正二层切片描述与复习标记，这些未动；如需全面对齐边界文档与现行实现，需另立一项。
3. **CODEBUDDY.md 仍称 R11 报告“有条件通过”**：沿用该报告自身的说法，本次未重新验证 R11 结论；Win11 真机复核事项仍以该报告 §9 为准。
4. **全量测试未跑**：按任务要求本次未跑测试、未跑 analyze；文档中凡涉测试结论处均未写通过数，只写测试文件位置或“以最终验证为准”。
