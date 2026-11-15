# 第三批修复汇总（B3-SUMMARY）

- 时间：2026-11-14
- 范围：CodeBuddy 第二次全代码复审的 P0/P1 与细节项 + Meng 追加定的 3 项（第 3 项 `double` 封面折角不在本批，Meng 自己与 CodeBuddy 协调，未动）
- 分支：`ui-replication`；工作树 `~/workspace/quiz-master2-UI`
- 状态：**全部完成，未推代码**（按纪律：Batch 1/2/3 + spine-fix 改动在最终自审前不 push，Meng 看完自审汇总再决定）

## 逐项结果

### 1. P0-1 路径删除安全（报告 B3-P01-PATH-SAFETY.md）
- `resolveDataPath`（database.dart L148）：绝对路径默认返回 null，相对路径走 `_resolveInsideDir`；例外通道是显式 `allowAbsolute: true`（只限测试代码）。
- `_deleteDataFileIfUnreferenced`（L2152）：只接受 `slices/` 前缀，绝对路径/`imports/`/`..` 一律不删。
- `_deleteTaskDirIfUnreferenced`（L2195）：taskId 先过 `^[A-Za-z0-9_-]+$`，`../slices` 直接拦下（旧写法规范化后会递归删掉整个 `slices/`）。
- 备份恢复（L163/L2941/L2952）：新增 `isAllowedDataRelativePath`，`validateBackupData` 校验 `questions` 的三个路径列与 `collect_tasks.source_path`，非法抛 `BackupRestoreException`（带表/行/列/原值），拒绝整个恢复；zip 的 JSON 在文件进位前就校验。
- 受影响的 4 个测试夹具改走 `testDataDirectory` + 相对路径。
- 新增 `test/b3_p01_path_safety_test.dart`：26/26 通过。

### 2. P0-2 测试隔离（报告 B3-P02-TEST-ISOLATION.md）
- `p0_hardening_test.dart` §4.1：测试体一字未动，意图保留（并发 `instance.db` 仍真实走 `_openDb`，只是在临时目录建库）；文件级 setUp 建临时目录 + `testDataDirectory`，tearDown 用 `resetForTest()` 复位。
- `s8b3_startup_test.dart`：改用 `openForTest()` 内存库 + `useDatabaseForTest` 挂为单例；删了直读真实演示库的旧写法。
- `s8b6b7_leftover_test.dart`：改用 `openForTest()` 内存库；删了读真实库文件、复制、再打开副本的旧逻辑。
- 空数据目录验收：真实数据目录移开后三文件合跑 24/24，跑完真实目录未被重建。

### 3. P1-1 二层切片降级（报告 B3-P11-LAYER2-DOWNGRADE.md）
- `regionsOfQuestion`（widgets.dart L23–35）：空 `sliceText` 时返回空列表，不再推导假 region；非空时规则不变。
- 整理页 `_leftPane`（L712–724）：无区域时整行隐藏开关（含前面的 10px 间距）；`_slicesSection` 只剩「整题框切片」一张卡。真实题不再显示开关与虚线框，只留整题切片；演示题行为不变；已存手动二层框未做任何读写改动。
- 新测试 `test/b3_p11_layer2_downgrade_test.dart`：6/6 通过；organize 26/26、B2 整理 4/4、widgets/uikit 36/36、detail + wrongbook 抽查 69/69。

### 4. P1-2 多页 PDF 未框页不丢（报告 B3-P12-UNBOXED-PAGES.md）
- 确认前弹框「还有 N 页没有框」，写明页码、有框页数、拆题数和“未框页会留在任务里”，按钮「取消」「确认拆题」；点取消什么都不拆。
- 只拆有框页；`confirmSplit` 删原任务后按同 id 重建保留任务——状态回 `needBox`、page = 首个未框页、pageCount/sourcePath/createdAt 原样保留、旋转角与未框页草稿写回；页图目录 `imports/<id>/` 不变，点「修框」可从首个未框页继续。
- 防重复拆：`_splitPagesFor` 以同 sourcePath 的拆分任务所在页为已拆页，重进再确认时跳过。
- 红色警告：`_taskRow` 在 needBox/boxing 行下出红色（`palette.errInk`）警告，文案按单页/多页区分——「这张图还没有框」「还有 N 页没有框：第 X、Y 页」「这份文件还有 N 页没有框」；未框页由 `_load` 按草稿框逐页算出。
- `collect_page_test` 全文件 42/42；P1-2 组 3/3、`pdf_collect_page_test` 1/1、新增 fallback 测试 2/2、`pdf_render` 13/13。

### 5. 细节项（分在 P01 / P11 / P12 报告中）
- `_restoreAutoBoxes` 的 hasManual 改为只认 `_boxes.any((b) => b.origin == 'manual')`（原写法恒为真）；只有 YOLO 框时不再弹确认。测试 2/2。
- 详情页「重新框选」单事务：新增 `replaceQuestionBoxesAndSliceInto` + 实例方法 + `repository` 透传（database.dart L2582/L2609，repository.dart L359），详情页 L368 由两步调用改为一次调用；旧 `replaceQuestionBoxes` 保留。切片文件仍在事务前写盘（残留见下）。
- `QuestionSlice` 的 `Image.file` 加 `errorBuilder`（widgets.dart L332–333），复用缺图占位（学科图标 + 学科·题型 + 「图片缺失，可重新导入/重新框选」）；原缺图分支抽成 `_missingImagePlaceholder`（L275），文件缺失分支（L340）改为调用它，文案逐字不变。
- `_importPdf` 兜底 catch（import_service.dart）：读页数与整本渲染两个 try 各加 `catch (e)` 兜底，走 `_failAndClean`；测试用注入假引擎抛 `FileSystemException` 模拟磁盘满。
- `_openDb` fallback 收窄（database.dart L636/L644）：新增 `shouldFallbackAfterOpenFailure`——只有主位置无库文件时才回退到安装目录 `data/`；已有库文件时任何打开失败都抛 `StateError` 明确报错。
- `copyDatabaseFileTo` 已删除（生产无调用，旧实现直接覆盖、失败留截断库）；迁移走 staging 的 `migrateDataFiles`；s8b4 的 B4.3 组改写为只测 `databaseExistsAt`。
- `QmFoldSection` 注释改对（uikit.dart L1683–1689）：核实全部 5 处调用方后写明——组件本身不做互斥，整理/详情/收集用独立布尔值可多开，设置/学科管理用单个 open key 只开一段，互斥是调用方的选择。只改注释，不改行为。

### 6. 追加项 1：整理页叠加层用真实 Layer-2 框坐标（报告 B3-OVERLAY-LAYER2.md）
- 新增 `layer2BoxToSliceRect`（widgets.dart L59）：页图坐标 → 切片坐标换算，`x'=(x−lx)/lw`、`y'=(y−ly)/lh`、`w'=w/lw`、`h'=h/lh`，钳制进 0..1（切片即页图按 layer-1 框裁出，确认时框已随页图旋转烘焙到同一坐标系，与已有实现一致，非新定）。
- 新增 `realRegionRects`（L77）：从某题全部框算出各区域的切片 0..1 矩形；`QuestionRegionOverlays` 新增可选参数 `realRects`（L113）：有真实框的区域按真实框画，无框的区域回退原示意框（示意几何逐字未变）；`showQuestionZoomDialog` / `_ZoomDialog` 新增 `realRegionRects` 直通参数（L813、L1052），放大浮层同样画真实框。
- 整理页新增 `_realRegionRects` 状态（L101）与 `_loadRealBoxes()`（L251）：`pageImagePath` 为空时不读库；有页图时走仓库已有的 `boxesForPageImage` + `questionId` 过滤再换算；切题时先清旧框，带 mounted/同题校验防竞态。
- **P1-1 红线守住**：是否显示仍只由 `regionsOfQuestion` 决定。真实题（空 `sliceText`）即使库里有框也不画框、不出开关；本次只改变“画在哪”，只影响仍显示区域的演示/老题。
- 新测试 `test/b3_overlay_layer2_test.dart`：14/14 通过；回归 organize 26/26、P1-1 降级 6/6、B2 整理 4/4、widgets/uikit 36/36。

### 7. 追加项 2：删除确认统一模态弹窗 + 修框右键拖动画框（报告 B3-DELETE-CONFIRM.md）
- (a) 失败任务「删除任务」（collect_page.dart:1299）由直接删的 `_removeTask` 改走已有的 `_deleteTask` 模态弹窗；「取消导入/取消排队」仍直接删（原设计保留）。
- (b) 审计全项目 20 个删除点（报告里有完整清单：文件+行号、原来形式、改后形式、文案保留情况）。行内确认条改掉的有：详情删题、整理队列单删+批量删、学科/章节/知识点/标签/试卷（5 处）、错题本文件夹删除+批量删除、设置清空演示数据/孤儿清理/恢复（恢复是覆盖不是删除，但共用同一行内确认条，按「行内确认条全部改掉」一并改）。各处原有后果文案、确认按钮文案原样保留；删除了 `_confirmTarget` / `_confirmBox` / `_pendingDeleteId` / `_batchDel` / `_deleteConfirmFolder` / `_batchDeleteConfirm` / `_confirmClearDemo` / `_orphanConfirm` 等内联状态。无删除入口的点（复习记录、设置清理缓存、修框删选中框、芯片 ×）经核查后未动；详情页取消编辑的三选一内联框不是删除确认，保留。
- **关键发现（已处理）**：整理队列弹窗不能走 `showDialog`。队列层是直接插进 Navigator overlay 的 `OverlayEntry`，新推的路由插到它下面、会被盖住点不到按钮（实测批量删除点「确认删除」命中了队列列表行）。改法：在队列层自身 Stack 顶层渲染 `ModalBarrier` + `AlertDialog`（organize_page.dart:2512-2540，Completer 回值），形式仍是模态弹窗；Esc 开着确认框时先关确认框。
- (c) 修框右键：根因不只是 `_onDrawStart` 的框内拦下——画框层压在框下面，而 Stack 的 hit-test 在第一个命中子节点就停，落在框上的右键根本到不了画框层。修复：右键画框/取消移到画布祖先级 Listener（命中路径上必然收到，collect_page.dart:2478 起），`_onDrawStart` 加 `fromRightDrag` 参数（:2146）跳过框内拦下；左键拖框仍走框的 GestureDetector，触摸画框仍在内层；4px 阈值与右键单击取消不变；提示文案的「空白处」限定已去掉。
- 验证：collect 43 项、detail+organize 52 项、subjects+wrongbook+settings 90 项全过；`flutter analyze` 全量 0 问题。新增测试：失败任务确认流程、「B3 右键起点在框上画新框、左键在框上仍拖动」。

### 8. 文档（报告 B3-DOCS.md）
- **代码地图.md**：12 张表 version 1 → **13 张表、schemaVersion 2**（新增 `question_boxes`）；讲清 `schemaVersion` 与 sqflite `version`/`user_version` 的区别；建库流程改为老库删掉重建（无迁移、无 `onUpgrade`）；依赖 3 个 → 全部 6 个（`sqflite_common_ffi ^2.3.6`、`path ^1.9.1`、`file_picker ^8.0.0`、`onnxruntime ^1.4.1`、`pdfrx_engine ^0.9.2`，dev `flutter_lints ^5.0.0`）；多值字段逗号分隔 → **JSON 字符串数组**；备份 8 张表 JSON → 含文件 zip、13 张表全在 `backupTables`；§8“YOLO 占位”整节重写为真模型；新增“演示库是 v1”与“第三批关键行为”小节。
- **CODEBUDDY.md**：“当前状态”整节重写：YOLO 占位/`hasRealModel` false/Google Drive 未接入/head `0d9d15d` 全部删掉，改为第 1 层真模型、模型不进仓库、第 2 层暂缓、Schema v2/13 张表、演示库 v1、测试隔离钩子、Batch 1/2/3 未提交未推送（最终自审前不 push）；决策记录改为 D-00～D-23。
- **README.md**：结构树“version 1”→“schemaVersion 2，13 张表”；`demo_data` 行注明演示题只定义、不预置（新库从空开始）。
- **模块边界文档**：复习改为已确认：§5.2 整节移为 **§4.5**（内容一字未动），§5.3/§5.4 顺延，计数同步为“已确认 5 页、未确认 3 页”；§4.2/§4.3/§5.1 二层描述按现状修正（第 2 层只有手画、真实题隐藏 region 开关、叠加层有真实框用真实框、无框回退示意、P1-2 未框页保留、单框不旋转、失败任务删除也要弹确认框）。

### 未做的事（按决定）
- P0-3：v1 库保持直接删除，未动代码。
- `double` 双线框封面折角：未动（Meng 自己与 CodeBuddy 协调）。

## 最终验证（协调员亲自跑，2026-11-14）

- `flutter analyze`：**No issues found!（0 问题）**（之前 `test/collect_page_test.dart:85` 的 warning 已消除）。
- 全量测试：**628/628 通过，0 失败**（Batch 1 结束时 560）。验收在**空数据目录**下跑：真实数据目录 `~/.local/share/quiz-master2` 事先移开，跑完未被重建——全套件不再碰真实库。`LD_LIBRARY_PATH` 含 onnxruntime-1.4.1，`TMPDIR` 在工作区。
- Linux Release 构建：**成功**，`✓ Built build/linux/x64/release/bundle/quiz_master2`。
- 演示库：跑全量测试前备份到 `~/workspace/demo-db-backup/quiz-master2.db.b3-final`；跑完恢复，md5 全程 `8f7f9c64405dc6e484ac2bf8e5e1a807`，未被改写（仍是 v1、9 题、3 学科）。
- 工作树：Batch 1/2/3 改动全部未提交（37 个文件，+10342/−2467，相对本地 HEAD bca8586），未推代码；未动 `assets/models/`，未动 `test/fixtures/`。

## 改动文件（本批主要）

- `lib/data/database.dart`、`lib/data/repository.dart`
- `lib/modules/collect/collect_page.dart`、`lib/services/import_service.dart`
- `lib/modules/organize/organize_page.dart`、`lib/modules/detail/question_detail_page.dart`
- `lib/modules/subjects/subjects_page.dart`、`lib/modules/wrongbook/wrongbook_page.dart`、`lib/modules/settings/settings_page.dart`
- `lib/widgets/widgets.dart`、`lib/widgets/uikit.dart`
- 新测试：`test/b3_p01_path_safety_test.dart`、`test/b3_p11_layer2_downgrade_test.dart`、`test/b3_overlay_layer2_test.dart`、`test/import_service_pdf_fallback_test.dart`；改动：`test/p0_hardening_test.dart`、`test/s8b3_startup_test.dart`、`test/s8b6b7_leftover_test.dart`、`test/collect_page_test.dart`、`test/pdf_collect_page_test.dart`、`test/organize_page_test.dart` 及其他页面测试
- 文档：`docs/代码地图.md`、`docs/CODEBUDDY.md`、`README.md`、`docs/quiz-master2-mo-kuai-bian-jie-hua-fen.md`

## 遗留问题与需 Meng 决定的事

1. **模型文件未被 `.gitignore` 忽略（需决定）**：`git check-ignore` 返回 exit 1，`.gitignore` 里无 `assets/models` 相关行；38MB 模型目前只是未提交，一次 `git add .` 就会进仓库。是否补忽略规则，需 Meng 决定（本次按纪律未动）。
2. **红色警告的范围（需决定）**：按字面规则实现，对“从未打开过的新导入任务”也会显示无框警告；是否收窄（例如只对已检测过的任务显示），待定。
3. `_importPdf` 末尾成功路径的 `upsertCollectTask(done)` 仍在两个 try 之外，若它本身抛错仍会逃出 `enqueue`，未动。
4. `CompactSliceThumb` 的 `Image.file` 没有 `errorBuilder`（本次只要求 `QuestionSlice`，未动）；`failed` 分支与缺图分支文案略有不同，未统一。
5. 叠加层：同区域多框取第一个，无确定性优先级；修框切片段未接线；未在真机上用真实库的手动框验证显示效果。
6. 详情页重框：切片文件仍在事务前写盘，事务回滚时可能残留新切片文件（无数据不一致，但有孤儿文件，孤儿清理可回收）。
7. 整理队列确认框非路由级弹窗（无路由返回键处理，Esc 由队列层自己处理）；详情取消编辑内联框保留（不是删除确认）；内框模式下右键起点在外框之外时仍按原行为退出内框模式、不画框。
8. 边界文档 §4.2/§4.3 仍有范围外的旧描述（如整理表单字段顺序仍写“学科、文件夹……”开头，与 2026-11-12 决定不符），需另立一项全面对齐。
9. 过程中收集工人曾误杀两个疑似兄弟工人的 flutter_tester 进程（PID 25543、25568）；最终全量测试由协调员统一重跑，628/628 通过，无残留影响。
10. `organize` P1-1 对照用例批量跑时曾偶发失败，单独跑 26/26 不复现；最终全量 628/628 通过，未复现。

## 报告索引

- `docs/ui-replication/B3-P01-PATH-SAFETY.md`
- `docs/ui-replication/B3-P02-TEST-ISOLATION.md`
- `docs/ui-replication/B3-P11-LAYER2-DOWNGRADE.md`
- `docs/ui-replication/B3-P12-UNBOXED-PAGES.md`
- `docs/ui-replication/B3-OVERLAY-LAYER2.md`
- `docs/ui-replication/B3-DELETE-CONFIRM.md`
- `docs/ui-replication/B3-DOCS.md`
- 本文件 `docs/ui-replication/B3-SUMMARY.md`
