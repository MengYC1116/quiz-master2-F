# 第五批第二阶段 P1 丢数据/覆盖类修复报告（B5-P1-DATA）

- 时间：2026-11-14
- 范围：最终自审 P1 丢数据/覆盖类 10 项（SR-P1-2、SR-P1-3、SR-P1-4、SR-P1-5、SR-P1-6、SR-P1-7、SR-P1-8、SR-P1-14、SR-P1-16、SR-P1-17）
- 分支：`ui-replication`；工作树 `~/workspace/quiz-master2-UI`
- 状态：**全部完成，未推代码**

## 逐项结果

### SR-P1-5 + SR-P1-6（同一根因，只修一处）

- 根因：编辑器内外 2 层框的键/分层口径不统一。修法：`box_editor.dart` 新增顶层函数 `normalizeBoxEditorInputs`，在编辑器 `initState` 一次收敛（裸键按父框所在页补 `'<页>:<父框id>'`；混进 `boxesByPage` 的 2 层框按 `parentBoxId` 拆进 `inners`/`standaloneInner`；重复 id 去重；`parentBoxId` 与键对齐）。详情页与收集页的传参一字未动。另堵住归一化引入的回归：`initState` 与 `_autoDetectIfEmpty` 的“有草稿/空页”判断都按三处（1 层、2 层、独立题内框）算，否则只有 2 层框的页会被检测覆盖。输出侧 `_currentDraft` 也对齐 `parentBoxId`。
- 结果：详情页重框已存 2 层内框可见（题级框内嵌套显示），双击进内框模式沿用旧框（不再造 stem/option/figure 三个默认框），确认后只入库 1 个内框；收集页继续修框草稿 2 层框不再混进 1 层框，确认后仍在 `inners`（不再丢弃），内框模式下可拖动（60×40 实测位移）、可删除。
- 测试：新 `test/b5_p1_256_test.dart` 10/10（归一化单测 5 + P1-5 widget 1 + P1-6 widget 2 + P1-2 内存库 2），做过反向验证（临时绕过归一化，P1-5 与 P1-6 确认测试失败，随后完整还原；P1-6 拖动/删除测试曾因操作到默认框而误通过，已补可区分断言）。

### SR-P1-2 确认拆题保留任务重建进事务

- 修法（首选方案）：`confirmSplitIntoImpl` 新增可选参数 `retainedTask` / `retainedBoxesByPage` / `retainedInners` / `retainedStandaloneInner`，同一事务内先删原任务、后插保留任务（同 id）并写回未框页草稿（含旋转角）；`inners` 按键里页码全量取（特意绕开 `saveDraftBoxesIntoImpl` 只取 1 层父框 inners 的取法）；三层透传（`database.dart` / `db_collect.dart` / `repository.dart`），`collect_page.dart` 改为确认前构造、随拆题一起提交。调用方不再事务外两步重建，崩溃窗口已关。Batch 3 的 P1-2 行为原样保留（确认前报未框页数、点取消不拆、保留任务回待框选从首个未框页修）。
- 改动：`lib/data/db_collect.dart`、`lib/data/database.dart`、`lib/data/repository.dart`、`lib/modules/collect/collect_page.dart`、`lib/modules/collect/box_editor.dart`。

### SR-P1-7 整理页打开队列层前先保存

- 修法：`_openQueue` 改为异步，打开队列层之前先 `await _saveCurrent()` 落盘，再把刚保存的表单行写回内存 `_queue`，然后再拍快照。只落盘不够：批量操作用旧 `Question` 做整行覆盖还会抹掉改动。保存后、插层前再 guard 一次，避免重复点开插两个层。队列弹窗本身交互未动（勾选只活在弹出层内，关闭即丢弃）。
- 测试：`organize_page_test.dart` 29/29（含新增 3 个，均做过反向验证——临时去掉修复后 3 个全失败、恢复后全绿）。

### SR-P1-4 + SR-P1-14 + SR-P1-17（import_service）

- SR-P1-4：`_importPdf` 末尾的 `upsertCollectTask(done)` 包进 try/catch，失败走 `_failAndClean`（再失败也只返回内存里的 failed 任务）；`enqueue` 的 `_importPdf` 调用点后收尾 upsert 也加兜底。写库失败不再逃出 enqueue、不卡 importing、不中断整批。
- SR-P1-14：图片 20MB 改为硬判，与 PDF 50MB 同款（复制前先判，超了直接进 failed 任务）；PDF 失败文案一字未动。`oversizeHint` 改成“超过 XMB 上限，导入会失败。”；收集页超限横幅标题/正文同步统一。
- SR-P1-17：去重收进 `enqueue`，按源路径去重，同批重复文件只建一个任务；删掉已死的 `existing` 快照 + `duplicate` 空分支。跨批重复有意不拦（D-08：收集页弹“已经导入过”后用户确认仍可重导，否则“仍然再导一份”按钮会静默失效），回归测试把该口径锁死。
- 测试：新 `test/import_service_p1_fixes_test.dart` 8/8（P1-4 用 BEFORE UPDATE 触发器模拟收尾写库失败；P1-14 用 21MB 图片；P1-17 同批/跨批去重对照）；相关旧测试 44/44。

### SR-P1-3 deleteExam 包事务

- 修法：删掉无意义的 `name=''` 那行，新增事务版 `deleteExamFromImpl`（删试卷行 + 题上 `exam_id` 置空包进 `db.transaction`）+ 静态转发；`deleteExam` 改走新方法。调用方 `repository.dart:287`、`subjects_page.dart:285` 未动。
- 测试：新 `test/b5_p1_3_delete_exam_test.dart` 3/3（删后置空、中途失败整体回滚、删不存在的不抛错）；相关既有测试 53/53。

### SR-P1-8 详情页重框隐藏缩略图条

- 修法：`box_editor.dart` 的 `_thumbStrip` 仅非重框模式渲染（`if (widget.mode != BoxEditorMode.rework)`）。源页 ≥2 的题进“重新框选”后没有“第 1 页”缩略图可点，切空页的路径不存在；标题仍显示真实源页码，框仍在画布上，确认后框不丢失。草稿模式缩略图条照常。未采纳报告另两点（`_switchPage` 在 `pageCount==1` 时拒绝切换、缩略图下标显示真实页码）：条已整个隐藏，`_switchPage` 在重框模式下不可达，不留无用防线。
- 测试：`detail_page_test.dart` 27/27（含新增 1 个），`collect_page_test.dart` 43/43。

### SR-P1-16 YOLO 加载失败不锁死

- 修法：`_ensureLoaded` 改为成功后缓存复用（`_loadOk`）、失败不留任何“已尝试”标记，下次检测重新尝试加载；旧 `_loadAttempted` 字段已删除（与 `_loadOk` 等价且只写不读，analyze 曾报 `unused_field`）。新增 `_loadFuture` 在途 guard，并发检测共用一次加载，避免 38MB 模型重复加载；失败时清空在途标记并置空会话。核查全部 `detectPage` 调用方：自动检测失败路径本来就是静默的，仅用户主动点“恢复自动框”时才按点击弹一次提示，重试不新增打扰。
- 测试：`yolo_onnx_service_test.dart` 25/25（含新增回归测试：首次失败后补放模型、下次检测恢复、无需重启），`p05_image_pipeline_test.dart` 13/13。说明：测试里“补放模型”是用换回真实模型路径模拟的，真机补放是否立即生效可在 Win11 验收时顺带确认。

## 阶段统一验证（协调员亲自跑）

- `flutter analyze`：**No issues found（0 问题）**。
- 全量测试：**661/661 通过，0 失败**（P0 结束 635 + 本阶段新增 26：P1-3 的 3 个 + P1-16 的 1 个 + P1-8 的 1 个 + P1-7 的 3 个 + P1-4/14/17 的 8 个 + P1-256 的 10 个），`LD_LIBRARY_PATH` 含 onnxruntime-1.4.1。
- Linux Release 构建：**成功**（`✓ Built build/linux/x64/release/bundle/quiz_master2`）。
- 演示库：跑前备份 `~/workspace/demo-db-backup/quiz-master2.db.b5-start` 已存在；跑完 md5 仍为 `8f7f9c64405dc6e484ac2bf8e5e1a807`（v1、9 题、3 学科），未被改写。
- 未提交、未推代码；未动 `assets/models/` 模型文件与 `test/fixtures/`。

## 环境说明

- VM 替换后真 clang 丢失（`/usr/lib/llvm-18/bin/clang` 不存在），阶段验证前跑 `docs/ui-replication/restore-linux-toolchain.sh` 恢复（约 85 秒）：ninja、clang/clang++ 18.1.3、GTK 3.24.41、ImageMagick、xdotool 均已装回。测试阶段曾复用 `/tmp/clang-shim/clang`（exec gcc 垫片），构建仍需真 clang。垫片在 /tmp，重启即失；工具链亦可能随 VM 重启再丢，后续阶段验证前先检查 `which clang ninja`，缺失即重跑恢复脚本。

## 遗留问题与待请示项（不属本阶段范围，未修）

1. SR-P1-7 相邻问题：`_saveCurrent` 只写库不同步内存 `_queue`，`_jumpToQuestion` / `_goTo` 等切题路径保存后也不刷新刚保存的那一行；切走再切回来时表单可能显示旧值（库里是对的，再一切题或一刷新就恢复）。建议另立一项根治（在 `_saveCurrent` 内统一把保存后的行写回 `_queue`）。
2. SR-P1-4 相邻问题：图片分支末尾的 `upsertCollectTask(needBox)` 也是 try 之外的同款形状，可另立一项加固。极限情况：库坏到 `_failAndClean` 重试也失败时，库里任务行仍停在 importing（已无法再写库），只有内存任务显示 failed、整批继续，无进一步修法。
3. `saveDraftBoxesIntoImpl` 本身仍只取“boxesByPage 里 1 层父框的 inners”——本次链路已绕开它，不受影响；是否顺手修它请定（属 SR-P2-14 附近口径，不宜在本批扩大）。
4. `dart format`：P1-256 工人只手工修了自己新增行的格式；树上既有的格式漂移未动（疑似 formatter 版本差异）。
