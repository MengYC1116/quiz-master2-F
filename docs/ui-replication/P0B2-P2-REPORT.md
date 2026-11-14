# P2 主链打通（图片链）实施报告

- 分支：`ui-replication`（未 commit、未 push）
- 方案：`docs/ui-replication/DB-CHANGE-PLAN.md` v2.1（§1、§3、§7 的 P2 行）
- 范围：只做图片链；PDF 导入现阶段显式提示“暂不支持 PDF”，渲染库选型与接入是最后单独一轨
- 日期：2026-11-14

## 验证总览

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 问题 |
| 全量 `flutter test` | **493 通过、0 失败**（基线 462，新增 31；YOLO 冒烟需设 `LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`） |
| Linux Release 构建 | 成功；`bundle/lib` 含 `libonnxruntime.so.1.15.1`、`libsqlite3.so`；模型已打包进 `data/flutter_assets/assets/models/question/yolo11s-question-v1.onnx` |
| Xvfb 真机端到端 | 主链通过（见下）；演示库已恢复原状 |

---

## A. §3 多值字段 JSON（先做的前置）

- `lib/models/models.dart`：新增 `ReviewQueueItem {questionId, cause}`（带 `==`/`hashCode`）；`ReviewSessionState.queue` 改为 `List<ReviewQueueItem>`；新增 `hasBannedNameSeparator(String name)`（禁 `,` `，` `|`，三处 UI 调用点共用）；`QuestionBox.copyWith` 增加 `String? id` 参数。
- `lib/data/database.dart`：新增编解码收口 `encodeStringList` / `decodeStringList` / `encodeRemedyList` / `decodeRemedyList` / `encodeQueue` / `decodeQueue`（空串/NULL 解码为 `[]`，编码空列表写 `'[]'`，非法值按空列表处理，不猜逗号拆分）；`_toRow` / `_fromRow` 五列、`_causeFromRow` / `_causeRecordToRow`（remedy_history）、`_seedCauseRecordsFor`（写 `'[]'`）、`saveReviewState` / `loadReviewState`（ReviewQueueItem 对象数组）、`_deleteFolderTxn`、`renameTag` / `deleteTag` / `deleteKnowledgePoint` / `deleteChapter`（改走 encode + 事务化）、`_removeFromReviewQueueTxn`（按 questionId 匹配）全部改完。
- `lib/data/repository.dart`：`saveReviewState` 签名改为 `List<ReviewQueueItem>`。
- `lib/modules/review/review_page.dart`：`_blocksFromFlat(List<ReviewQueueItem>)`（删 `split('|')`）、`_flatQueue()` 返回 `(List<ReviewQueueItem>, int)`、`_load` 断点校验的 pendingKeys 改为 `Set<ReviewQueueItem>`。其余 `|` 拼串（report_page、review_page 的 `_skips` 键、分组键）是内存 map 键，不在方案 §3.4 范围，未动。
- 全仓库 grep 裸 `join(',')` / `split(',')` / `split('|')`：lib 内只剩 `database.dart:1530` 的 SQL 占位符构造（`List.filled(...).join(',')`，合法）和两处注释字样。
- 输入限制（§6 第 4 条）：仅标签名和自定义错因名禁 `,` `，` `|`，命中时提示“不能含逗号或竖线”。已加到 `subjects_page.dart` 的 `_addTag` 与 `_renameName` 的 `case 'tag'`、`organize_page.dart` 的 `_submitNewTag` 与 `_addCustomType`、`question_detail_page.dart` 的 `_newTag` 与 `_newCustomErrorType`。
- 测试：`test/p2_json_fields_test.dart`（新建，12 项）——编解码（含 `,`/`|`/`---`、空串/NULL/非法值）、11 处写点（删文件夹/改标签/删标签/删知识点/删章节后重读题仍能正确解析，含逗号的标签原样保留）、手写旧格式行（裸逗号串）读出为空列表、queue 含 `|`/逗号编解码往返、`_seedCauseRecordsFor` 写 `'[]'`。
- 顺带修：`test/p0_hardening_test.dart` 3 处失败（P0 种子用旧逗号格式，`_fromRow`/`decodeStringList` 对非 JSON 返回 `[]`）——种子改为 JSON，12/12 通过。

## B. §4 遗留两项

- `renameTag` / `deleteTag` / `deleteKnowledgePoint` / `deleteChapter` 各拆出静态可单测版 `renameTagFrom` / `deleteTagFrom` / `deleteKnowledgePointFrom` / `deleteChapterFrom`（一次 `db.transaction`，实例方法包一层；原有 bump 行为不变——这四个原来就不 bump）。
- 角标节流：`AppDatabase.upsertCollectTask` 改为先读旧 status，只有新行或 status 变化时才 `bumpBadgeVersion()`（进度百分比高频更新不 bump）。

## C. §1.4 导入复制

- `lib/services/import_service.dart` 全文件重写：布局常量/辅助 `taskDirRelative`（`imports/<task-id>`）、`originalRelative`（`imports/<task-id>/original.<ext>`）、`normalizedPageRelative`（`imports/<task-id>/page-normalized.png`）、`bakedPageRelative`（`imports/<task-id>/pages/page-<p>-r<角度>.png`）、`sliceRelative`（`slices/<question-id>.png`）、`pageImageRelativeForTask`（归一化副本存在时用它，否则 source_path）、`storageUsageBytes()`（imports/+slices/ 合计）、`maxStorageBytes = 2GB`。
- `enqueue(paths, {subjectId, onProgress})`：任务先建行为 importing；PDF → failed 任务，error 为“暂不支持 PDF：PDF 导入还在接入中，先用 JPG / PNG 照片导入”；空间超 2GB → failed；按字节流式复制（0→70%，`onProgress(taskId, progress)` 回调，进度写库走无 bump 的 `upsertCollectTaskInto`）；复制失败删目录 → failed；EXIF 归一化（`normalizeExifImageBytes`）：镜像方向 2/4/5/7 → 删目录 → failed（“这张照片是镜像方向（EXIF N），暂不支持，请先转存为正向照片再导入”）；方向 3/6/8 生成归一化 PNG 副本；成功后 status=needBox、progress=100、source_path 写相对路径（状态变化才 bump）。
- 拖放区文案改为“先收 JPG / PNG 照片；PDF 暂不支持，接入后会再开放（Word 先导出成 PDF 再导入，PDF 接入后可用）”；`_simulateImport` 假进度已删。
- 测试：`test/p2_main_chain_test.dart`（新建，13 项）含导入复制——enqueue 后 `imports/<task-id>/original.jpg` 存在且字节一致、任务 source_path 为相对路径、status=needBox、进度回调走到 100；PDF → failed 且 error 含“暂不支持 PDF”；EXIF 方向 6 → 生成 `page-normalized.png`；方向 1 不生成副本；镜像方向 2 → failed 且提示镜像方向、导入目录已删。

## D. §1.5 修框读写 question_boxes

### 基础设施（`lib/data/database.dart`）

- `import 'dart:math' as math`；`@visibleForTesting static String? testDataDirectory` + `dataDirectoryPath()` 优先返回它；`static String? resolveDataPath(String path)`（相对路径拼数据目录并校验不越出，`..` 越界返回 null；绝对路径原样规范化返回）；`static String newBoxId(String scope, int page)`（`box-<scope>-p<page>-<uuid8>`，见实施注意 3）；`@visibleForTesting static void useDatabaseForTest(Database db)`。
- 框 DAO（静态可单测版 + 实例版）：`boxesForTaskFrom` / `boxesForTaskPageFrom`（草稿框，`question_id IS NULL`）、`boxesForPageImageFrom`（按 `questions.page_image_path` 分组，读同页全部已确认题的框）、`saveDraftBoxesInto` + 实例 `saveDraftBoxes`（一次事务：按页替换草稿框 + `page_rotations` 一起写；不 bump）、`replaceQuestionBoxesInto` + 实例版（只动一题，先删子框再删本体后插入）、`_deleteBoxesForQuestionTxn`、`confirmSplitInto` + 实例 `confirmSplit`（四步同事务：建题 + 回填 question_id（先删旧框防 partial unique 冲突）+ 建拆分任务 + 删原任务及残留草稿框；拆分任务的 created_at 随行写）。
- `lib/data/repository.dart` 增加框包装：`boxesForTask` / `boxesForPageImage` / `saveDraftBoxes` / `replaceQuestionBoxes` / `confirmSplit`。

### YOLO 服务（`lib/services/yolo_onnx_service.dart`）

- 新增 `DetectionResult {boxes, usedFallback, error}`（§1.3 定稿：模型失败不回占位框）。`detectPage` 返回 `Future<DetectionResult>`：文件不存在 → usedFallback=true，error“页图缺失：找不到这页的图片，请重新导入”；模型加载失败/推理异常 → usedFallback=true，error“自动检测不可用，请手动框选”；成功 → boxes + usedFallback=false。`_toPageBox` 填 `confidence: d.score`、`origin: 'yolo'`；`_placeholderBoxes()` 已删。新增 `@visibleForTesting static void resetLoadStateForTest()`。

### 收集页（`lib/modules/collect/collect_page.dart`）

- `CollectPage` 增加可选参数 `yoloService`（可注入；测试用桩服务可返回固定检测结果）。
- `_importFiles` 重写：用 `service.enqueue(..., onProgress:...)` 真实导入（进度变化时才 setState；PDF/复制失败/镜像方向进失败任务）；保留原有 pre-check（不存在/空文件/加密 PDF → `_failTask`）。
- `_openBoxEditor` 重写：先算页图路径（`ImportService.pageImageRelativeForTask` + `AppDatabase.resolveDataPath`），缺失 → snack“页图缺失：找不到这份文件的页图，无法修框，请重新导入”且不开编辑器（§6 第 6 条）；置 boxing；草稿优先（有草稿框就用草稿不再检测）；无草稿才检测，检测结果按草稿已存旋转角度经 `rotateBoxToRotatedPage` 变换再进框列表（实施注意 1）；检测失败 → `detectError` 传进编辑器（不落占位框）。
- 新增公开 API：`enum BoxEditorMode { draft, rework}`、`class BoxEditorResult {boxesByPage, inners, standaloneInner, rotationsByPage}`、`showBoxEditorDialog({...})`（收集页与详情页共用入口；draft 模式 onSaveDraft 在取消/切页时调，rework 模式 onSaveDraft 为空、readOnlyBoxes 是同页其他题的 1 层框）。
- `_BoxEditorDialog` 重写参数：`pageImagePath`（必传，实施注意 4）、`taskId`、`mode`、`initialBoxesByPage`、`initialDetected`、`initialInners`、`initialStandalone`、`initialRotations`、`reworkQuestionId`、`readOnlyBoxes`、`detectError`、`yoloService`（必传）、`onSaveDraft`；另保留旧签名的 `fileName`、`page`、`pageCount`、`subjectName`（标题/显示用）。
- State 重写：`_inners` / `_standaloneInner` 改为 late 可赋值；新增 `_rotationsByPage`（按页旋转）；`_pageImageSize`（异步解码页图拿像素尺寸，未知时按 560×700 默认比例）、`_pageImageFailed`；`_anyOverlap` 在重框模式下把当前页的 readOnlyBoxes 也纳入校验；`initState` 从 initial 值初始化，本页无草稿才 `_ingestDetected` 检测结果。
- `_ingestDetected`：先 `_persistedId` 换 id + 设 page，再 clamp + groupInners。`_switchPage` 改为 async：先 `_saveDraftIfNeeded()` 再切页。`_restoreAutoBoxes` 重写：草稿模式——本页有框时先弹确认“用自动框替换当前页的手动框？”；检测失败 → SnackBar 显示 error（不替换、不写占位框）；成功 → 结果按当前页旋转 `rotateBoxToRotatedPage` 变换后 `_ingestDetected`（替换本页）。新增 `_restoreAutoBoxForRework()`（重框模式：取与当前目标框 IoU 最大的检测框，IoU ≤0.05 或无框时 SnackBar“没找到对应的题，请手动框选”；替换时保留目标框 id）。`_rotatePage`：按页 `_rotationsByPage[_currentPage]` +90，用 `rotateBoxToRotatedPage(b, 90)` 变换框；重框模式直接 return（禁用整页旋转，§1.6）。`_deleteSelected`、`_clampInner`、`_resizeBox`、`_confirmPendingType`、`_onDrawStart`、`_onDrawUpdate`、`_BoxEdit.movedBy` 均改为 `copyWith(...)` 只改坐标、保留其余字段。
- build()：帮助文案删掉“拖右上角圆柄旋转”，改为“框只能拖动/缩放，不旋转”；新增重框模式横幅、detectError 警告横幅（“自动检测不可用…请手动框选…”）、`_pageImageFailed` 错误横幅；画布 fit 改为按 `_pageImageSize ?? 560×700` 真实比例，旋转 90°/270° 时显示宽高互换。
- `_toolbar`：重框模式隐藏“旋转整页”按钮（§1.6）。
- `_canvas`：纸面 Container 改为真实页图渲染——`Image.file(File(widget.pageImagePath), fit: BoxFit.fill)` 包在按未旋转宽高放的 SizedBox 里，外层 `Transform.rotate(angle: _pageRotation * pi / 180)`；页图损坏时回退到纸面 + 三行说明文字；旋转 ≠0 时底部保留“整页已旋转 N°（图片和框一起转的）”提示；`_boxes`/`_standalone` 渲染分支后补 readOnlyBoxes 的 `_frozenBoxView`（只读，label“其他题 · 只读”）。
- `_foot`：取消按钮改为草稿模式先 `_saveDraftIfNeeded()` 再 `pop(null)`（重框模式直接 `pop(null)`）；确认按钮改为 `pop(_currentDraft())`。
- `_boxView`：删掉外层 `Transform.rotate(...)`；`_boxBody`：删掉选中框的右上角旋转圆柄（`Key('editor-rotate-${box.id}')` 的 Positioned + GestureDetector + `_rotateBoxFromGlobal` 调用）；`_rotateBoxFromGlobal` 已删。单框旋转禁用（§6 第 10 条）。
- `_confirmSplit(task, result, pageImageAbs, pageImageRel)`（§1.5/§1.6）：按页取 layer-1 框；旋转 ≠0 时 `rotateImageBytes` 烘焙页图写 `bakedPageRelative`（0° 不生成新文件）；每框 `cropBoxPng` 裁剪写 `slices/<qid>.png`（切片写盘在事务前，失败 snack“拆题失败：切片写不进去…”且库不动）；建 Question（含 sourcePath/sourceKind='image'/sourcePage/pageImagePath/slicePath/sliceWidth/sliceHeight）与拆分任务（含 source_path/created_at/page_count=原任务总页数）；框按题分组（含该题的 2 层子框）；最后 `repo.confirmSplit` 四步同事务 + saveRecentTask + snack“已生成 N 道题，去整理吧”。

### 详情页“重新框选”入口（`lib/modules/detail/question_detail_page.dart`）

- `_saveEdit` 补上 base 的 7 个图片字段（sourcePath/sourceKind/sourcePage/pageImagePath/slicePath/sliceWidth/sliceHeight）——此前全新构造 `Question(...)` 会抹掉它们，编辑一次真实题就变“无图题”。
- `_buildInfoSection` 增加 `_Field('重新框选', QmButton('重新框选这道题', plain, small, onPressed: _reworkBoxes), hint: '框错了可以重框：同页其他题的框只读，取消不改动')`，仅当 `q.pageImagePath != null` 时显示（演示题/老题无页图不显示）。
- 新增 `_reworkBoxes()`（§1.5.1）：页图缺失 → snack 报错不开编辑器（§6 第 6 条）；`repo.boxesForPageImage(q.pageImagePath)` 取同页全部框，目标题的 1 层框可编辑、其他题 1 层框只读（`readOnlyBoxes`），目标题的 2 层框作 initialInners/standalone 传入；调 `showBoxEditorDialog(mode: BoxEditorMode.rework, ...)`；取消返回 null → 丢弃；确认后取新 1 层框 `cropBoxPng` 重裁覆盖 `slices/<qid>.png`（写盘前先 `File(sliceAbs).parent.create(recursive: true)`——详情页 widget 测试发现的真 bug：此前无此行，slices/ 目录不存在时写盘失败；失败 snack“重新框选失败：切片写不进去”且库不动），先 `evictCachedFileImage` 再读，`repo.replaceQuestionBoxes(q.id, [新框 + 子框])` + `repo.save(q.copyWith(sliceWidth/sliceHeight...))`，`_load()`，snack“已重新框选，切片已更新”。

## E. 确认拆题

- 见 D 节 `_confirmSplit`：裁剪写盘在事务前、失败不写库；建题/回填 question_id/建拆分任务/删原任务四步同事务；页图旋转确认时烘焙进页图（`bakedPageRelative`，0° 不生成新文件）。
- 测试：`test/collect_page_test.dart`（28 项，+3）——“旋转后确认：页图烘焙 -r90，切片落盘”（题的 pageImagePath 含 `-r90`、烘焙文件存在、切片存在且 sliceWidth/Height > 0）；“取消保存草稿：重进‘继续修框’恢复上次的框”；“模型失败：不落占位框，显式提示手动框选”（横幅含“自动检测不可用，请手动框选”，画布内无“题级框 1”）。
- 测试环境发现：`_confirmSplit` 做真实文件 IO + 图片解码；flutter test 的 pump/pumpAndSettle 不推进 fake async zone 外的真实异步——隔离实验证实 `testWidgets` 体内直接 `await File.readAsBytes()` 永远挂起，`runAsync` 内 await 才能完成。解决办法：新增 helper `tapConfirmAndWait(tester, label)`——`runAsync` 内 tap + 循环 20 次（`pump` + 真实 `Future.delayed(200ms)`）+ `pumpAndSettle`。

## F. 各页读图

- `lib/widgets/widgets.dart` 增加 `dart:io` 与 `../../data/database.dart` import。`QuestionSlice` 抽出 `_realSliceBody`：`slicePath != null` 时 `AppDatabase.resolveDataPath` 解析，文件存在 → `Image.file(..., fit: BoxFit.contain, cacheWidth: (maxHeight*2).ceil())`；`slicePath != null` 但文件缺失 → 显示“图片缺失，可重新导入/重新框选”（subject 图标 + 该文案）；真实题有 sourcePath 但无 slice → 同样显示“图片缺失…”；`slicePath == null` 时仅 isDemo 或老题（sourcePath==null && slicePath==null）回退现有 sliceText 绘制；`failed=true` 的现有占位优先。
- `CompactSliceThumb`：slice 存在 → `Image.file`（cacheWidth 128）；真实题缺图 → failed 形态（14px 图标 + “图片缺失”，保留 P0B1 的溢出修复）；其余保持现有迷你条绘制。
- `lib/modules/organize/organize_page.dart` 的 `_slicesSection`：整题框切片卡有真实 slice 时显示 `QuestionSlice(question: q, maxHeight: 220)`；题干/选项/配图卡只在 sliceText 非空时显示（真实题不显示空白卡）。错题本大卡片与 zoom 浮层走 QuestionSlice，自动受益。
- 测试：`test/p2_main_chain_test.dart` 含各页读图 widget 测试（真实切片存在显示真图；slicePath 指向缺失文件显示“图片缺失，可重新导入/重新框选”；真实题有来源无切片同样显示缺图；演示题/老题走 sliceText 占位；CompactSliceThumb 有图显示图、缺图显示“图片缺失”）。
- 测试环境教训：(1) 有真图的 widget 测试里 `pumpAndSettle` 会等 `Image.file` 的真实解码（fake zone 里等不到完成）而挂起——只 `pump()` 一次断言 widget 结构；(2) `dart:ui` 的 `toImage`/`toByteData` 在 `testWidgets` 体内会挂起——切片 PNG 改在 `setUpAll`（真实 zone）里生成。

## 4 个实施注意的落实

1. **旋转后“恢复自动框”须先做坐标变换**——已落实：`_openBoxEditor` 检测后按草稿已存旋转角度经 `rotateBoxToRotatedPage` 变换；`_restoreAutoBoxes` 成功后同样变换。复用 P0.5 落成的 `lib/services/page_image_pipeline.dart` 里的变换，未重写。
2. **EXIF 方向检测用 P0.5 已定的手写轻量 JPEG APP1 解析**——已落实：`ImportService.enqueue` 内镜像方向（2/4/5/7）删目录后失败任务，错误含“这张照片是镜像方向（EXIF N），暂不支持，请先转存为正向照片再导入”。未引入 image 包，未改 pubspec。
3. **`QuestionBox.id` 的 uuid8 用 `Random.secure()` 生成 8 位十六进制**——已落实：`AppDatabase.newBoxId` 生成 `box-<scope>-p<page>-<uuid8>`。未引入 uuid 包。
4. **`_BoxEditorDialog` 增加 `pageImagePath` 参数**——已落实：`showBoxEditorDialog` 与 `_BoxEditorDialog` 均以 `pageImagePath`（必传）为底图与检测路径，`fileName` 只做显示。首次检测/恢复自动框/旋转后检测统一传页图路径。

## 验证结果

### 单元 / Widget 测试

- 全量 `flutter test`：**493 通过、0 失败**（基线 462 + 新增 31：`p2_json_fields_test` 12、`p2_main_chain_test` 13、`collect_page_test` +3（25→28）、`detail_page_test` +2（24→26）、`yolo_onnx_service_test` +1（占位测试拆成文件缺失与模型缺失两个））。耗时约 168 秒。
- `test/review_page_test.dart` 27/27、`test/p0_hardening_test.dart` 12/12 均通过（后者种子已改为 JSON，见 A 节）。
- `flutter analyze`：0 问题。

### Linux Release 构建

- 构建成功：`build/linux/x64/release/bundle/quiz_master2`；`bundle/lib` 含 `libonnxruntime.so.1.15.1`、`libsqlite3.so`、`libapp.so`、`libflutter_linux_gtk.so`；模型已打包进 `data/flutter_assets/assets/models/question/yolo11s-question-v1.onnx`。

### Xvfb 端到端（真实图片 + 真实模型，无截图，以 DB/文件状态为准）

环境：自启 Xvfb `:99`（1280×800，`-ac`；`xvfb-run -a` 会因 X auth 报错，须自启）；Release bundle 启动；窗口 1280×720；日志只有环境噪声（Atk-CRITICAL、GSettings assertion、libEGL DRI3 警告、Impeller 后端行），无应用错误。驱动靠 xdotool 点击 + `sqlite3` 查库 + 进程 CPU 尖峰（100ms 粒度采样）判定点击效果。

- **真实检测可用**：1653×2200 真实试卷页（`~/workspace/yolo-test-images/16676QPFVu1ck984AfWQHruoHWRfTz99b.png`）导入为 `task-e2e-1`（needBox）后，点“修框”，Release 包内真实 YOLO 检出 **15 个框**，取消后草稿落库 15 行（`question_boxes`，`collect_task_id='task-e2e-1'`）。`libonnxruntime.so.1.15.1` 已在进程 maps 中确认加载。
- **草稿重进 + 确认拆题**：草稿取消保存、重进恢复；确认后 **11 道题**已建（`questions`，subject math、source_kind image、source_page 1、page_image_path 与 slice_path 均已填、sliceWidth/Height > 0）、**11 张切片**落盘 `slices/<question-id>.png`、**11 个拆分任务** pendingOrganize、原任务已删、草稿框清零、11 个框已回填 question_id。
  - 注：真实检测的 15 个框中有 6 对重叠（IoU 最高 0.48），确认按设计被重叠校验拦下。e2e 为走通确认，用 SQL 把 15 个框反旋转回原页坐标后按面积删去重叠对中较小者、保留 11 个无重叠框（仅测试准备手法，非产品行为）。这说明真实检测在密集版面上常出重叠框，用户需手动调开才能确认——属检测质量现状，不是 P2 缺陷。
- **整理工作台**：导航进整理页，渲染尖峰 170–200%（11 道题真切片解码），应用存活、无崩溃。真切片渲染本身由 widget 测试覆盖（`p2_main_chain_test` 各页读图组）。
- **题目详情**：从整理页点“查看题目详情”进详情页（渲染尖峰 220–260%），点返回按钮弹回整理页（尖峰 180%），路由往返正常。
- **模型缺失**：把 bundle 内 `yolo11s-question-v1.onnx` 移走后重启，新任务 `task-e2e-2` 点“修框”，状态翻为 boxing，草稿 **0 框**（不落占位框）、无新题；随后把模型文件恢复原位。提示文案（“自动检测不可用，请手动框选”横幅）由单测覆盖（`yolo_onnx_service_test` 模型缺失用例），本次未读屏验证。
- **未在真机 e2e 完成**：详情页“重新框选”入口的端到端点击。原因：盲点坐标下，详情页三段在浏览态默认全折叠、点“待补充”会进编辑态并展开全部段、再叠加滚动偏移，按钮位置不可靠收敛。入口显示、编辑器打开（目标可编辑/他题只读）、确认重裁切片已由 widget 测试覆盖（`detail_page_test` 重框组 2 项）；重框编辑器与草稿确认共用同一 `_BoxEditorDialog` / `cropBoxPng` / `replaceQuestionBoxes` 路径，该路径已在真机 e2e 验证通过。

### 演示库恢复

- e2e 前备份 `/tmp/qm2-p2-demo-backup/quiz-master2.db`（94208 字节，v1）；验证后已拷回 `~/.local/share/quiz-master2/quiz-master2.db`，并删掉 e2e 产物（`imports/task-e2e-1`、`imports/task-e2e-2`、`slices/`）。核对：user_version=1、**9 道题、3 学科、深色（themeMode=dark）、pageSize=10**，其余设置（recheckIntervalDays=7、cureChecks=2 等）完整。应用与 Xvfb 已停。

## 附：e2e 驱动中的坐标经验（供后续真机验证参考）

- 收集页任务行：`Flexible(Wrap)` 与 `Expanded` 平分剩余空间，操作按钮在行中部而非行尾；任务列表超过 3 个时容器固定高 408 内部滚动，且筛选 chips 换行会把列表再顶下约 37px——行 Y 须按实际 chips 行数算。
- 对话框确认按钮：题数 >1 时标签变长（“确认修框，拆成 N 个待整理任务”），按钮随之变宽；本次命中点为 (900,580)，取消为 (822,593)。
- 键盘 Tab 在无窗口管理器的 Xvfb 下焦点不可靠（`XGetInputFocus` 返回 window 1）；鼠标点击 + CPU 尖峰（100ms 采样）+ DB 状态是最可靠的探针组合。
- `pkill -f` 的 pattern 若匹配到自己的命令行会杀掉自己的 shell——只用 `pkill -x`。
