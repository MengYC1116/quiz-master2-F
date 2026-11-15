# B2 Win11 Bug 批（工人 B）— 整理工作台 Bug 2 / 3 / 4 报告

- 分支：`ui-replication`（未推代码）
- 范围：只动 `lib/modules/organize/organize_page.dart`、`lib/widgets/widgets.dart`（框渲染）、`test/b2_win11bug_organize_test.dart`（新增）+ `test/fixtures/slice-narrow-500x120.png`（新增夹具）。未动 `collect_page.dart`。
- 演示库：开工前备份 `~/.local/share/quiz-master2/quiz-master2.db` 到 `/tmp/qm2-b2-workerB-backup.db`，md5 与协调员备份 `~/workspace/demo-db-backup/quiz-master2.db.b2-start` 一致（`8f7f9c64405dc6e484ac2bf8e5e1a807`）。全量测试后恢复并核对 md5（见“验证”）。
- 环境插曲：中途 `clang` 丢失导致 `flutter test` 原生构建失败（`pdfium_dart` hook 找不到编译器），按任务授权跑了 `docs/ui-replication/restore-linux-toolchain.sh`；第一次因 `libepoxy-dev` 的 deb 包下载损坏而中断，删掉该包后重跑成功（clang 18.1.3、GTK 3.24.41 正常）。

## Bug 2 + Bug 3 — 根因（与任务单上的怀疑不同）

### 先说结论：不是 Layer-2 框坐标系用错

任务单怀疑“Layer-2 stem 框坐标系用错（页图坐标 vs 题图裁切坐标）”。核查后**不是这个原因**：

- `question_boxes` 表：`x/y/w/h` 是**相对整页图的 0..1 坐标**（模型注释“相对页面的 0..1 坐标，钳制在页面范围内”，表上有 `CHECK (x >= 0 AND x <= 1)` 等约束），`parent_box_id` 指向所属 Layer-1 整题框，`layer` 1=整题 / 2=stem/option/figure。
- 但**整理页 / 放大查看 / 修框切片三处渲染全都不读 `question_boxes`**：`QuestionRegionOverlays`（`lib/widgets/widgets.dart`）按写死的比例画框（stem 上 34%、option 下 36%、figure 下 42% 居中 48% 宽），区域有无只按题型与题干文字推导（`regionsOfQuestion`）。截图里的 stem 虚线框根本不是库里存的 Layer-2 框，是推导出的示意框。所以不存在“页图坐标误当成题图坐标”的映射错误，也就没有坐标映射可修。
- 保存时夹取已存在：收集页修框编辑器改内框时 `_clampInner` 会把 Layer-2 框夹取到父框内；表级 `CHECK 0..1` 兜底。因此**本次不改保存逻辑**，只修渲染。

### 真正的根因：图按固有尺寸渲染，框按布局容器尺寸画

`QuestionSlice` 的真图分支是 `Image.file(..., fit: BoxFit.contain, cacheWidth: maxHeight*2)`，在 `Stack`（松约束）里按**固有像素尺寸**显示：宽条切片（如上报那题 500×120 级）固有宽小于左栏/对话框容器宽，图左对齐、右边留白；而 `QuestionRegionOverlays` 的 `LayoutBuilder` 取的是 `Stack`（= 容器）的宽高画框，`stem` 框 `left:10, width:w-20` 于是向右伸出图片一大截。option / figure 同一个叠加层、同一种画法，一并受影响（不是只修 stem）。

证据（测试复现，1280×720，夹具图 500×120）：

| 位置 | 修前 | 修后 |
|---|---|---|
| 整理页 overlay 宽 / 图宽 | 629 / 500 | 502 / 500（多 2px 是纸面容器 1px 边框 ×2） |
| 放大查看 overlay / 图（150% 缩放后） | 680 宽 Stack / 500 宽图 | 与纸面容器同宽 753 / 图 750（边框 × 缩放） |
| 修框切片卡宽 / 卡内图宽 | 591 / 268 | 292 / 268（多 24px 是卡自身内边距 20 + 两层 1px 边框） |

截图像素分析也一致：image-76 里 stem 虚线框横跨 x≈41→1058，而题图内容只到 x≈510；image-78 里“整题框切片”卡内没有任何虚线框，伸出图片的是**卡片边框本身**——Bug 3 的“stem 框”即此卡框（卡是 `Column(stretch)` 里的整宽容器，图窄于卡）。

### 改动

1. `lib/modules/organize/organize_page.dart` — `_paperImage`：`Stack` 外包一层 `Align(alignment: Alignment.topLeft)`，让 Stack 收成切片实际尺寸，叠加层与图同宽。演示题 / 失败占位是 `Center` 撑满容器，Stack 仍是容器宽，不受影响。
2. `lib/widgets/widgets.dart` — `_ZoomDialog`：`IntrinsicHeight` 与 `Stack` 之间同样包 `Align(topLeft)`（`_paperKey` 仍在 Stack 上，供初始居中矩阵量纸面尺寸）。副作用：初始缩放按真实纸面尺寸算，上报那类 500 宽的题徽标会从 132% 变为 150%（`min(1.5, fit)`，fit 变大所致；公式本身未变）。
3. `lib/widgets/widgets.dart` — `QuestionRegionOverlays`：返回的 `Stack` 外包 `ClipRect`，框一律按图片边界裁剪（修后框本就在图内，这是兜底，后续改区域几何也不会画到图外）。
4. `lib/modules/organize/organize_page.dart` — `_slicesSection` / `_sliceCard`（Bug 3）：整题框有**真实存在**的切片文件时，卡外包 `Align(centerLeft)`、卡头 Row 改 `MainAxisSize.min`（新增 `hugContent` 参数，`Spacer` 换 12px 间隙），卡收成图宽；文字卡（无真图）保持整宽不变；文件缺失时 `QuestionSlice` 显示缺图占位（撑满容器），不收窄。新增 `dart:io` 与 `database.dart` import（用 `AppDatabase.resolveDataPath` + `File.existsSync` 判断，与 `QuestionSlice` 内部同一做法）。

### 未做的选择（写清理由）

- **不把图拉满容器宽**（如 `width: double.infinity` + `BoxFit.contain`）：高被 `maxHeight` 封顶的题（矮胖比 < 约 2）会横向留白居中，叠加层仍会对不准；收 Stack 尺寸在所有长宽比下都准。
- **不接真实 Layer-2 框坐标**：那是功能改动（真实框只在导入题上有，演示题没有；且与“YOLO 只做第 1 层”的既定方向有关），超出本批 bug 修复范围；见文末“需 Meng 决定”。
- **不在保存时夹取坐标**：已存在（收集页 `_clampInner` + 表级 CHECK），无需重复做。

## Bug 4 — 表单各区独立折叠

### 结论：本树里该 bug 未复现，无需改代码，已用测试锁定行为

- 代码核查：四区一直是四个独立布尔值（`_folderOpen/_sourceOpen/_classifyOpen/_answerOpen`，各 `onToggle` 只翻转自己），`_loadForm` / `_refresh` / 确认流程都不碰这些标志；从 v2 重写（`010a524`）到 HEAD 皆如此，全分支搜不到整理页用单 `_openSection` 的版本。单 `_openSection` 互斥模式只在**学科管理页**（`subjects_page.dart`）存在，与本 bug 无关。
- 截图自证：image-79 里“文件夹（归类）”与“来源（可选）”同时显示“收起”（同时展开）。
- `QmFoldSection`（`lib/widgets/uikit.dart`）文档注释写着“调用方翻转该段的展开态并收起其他段”，与整理页实际行为不符，是过时描述。本批按分工未动 `uikit.dart`，建议协调员另行修正该注释（见文末）。
- 默认态未变：文件夹默认展开，其余默认折叠（`_folderOpen = true`，其余 `false`）。

### 测试

新增 `test/b2_win11bug_organize_test.dart`：默认态断言 + 依次打开“分类补充 → 来源 → 答案·解析·笔记”，断言三区（及文件夹）同时保持展开（另以“收起”数 4→5 佐证）。

## 回归测试（新增）

新增 `test/b2_win11bug_organize_test.dart`（4 项）+ 夹具 `test/fixtures/slice-narrow-500x120.png`（500×120 白底黑条，模拟真实宽条切片）：

- Bug 2 整理页：预热进 `imageCache` 的真图（`ResizeImage` 包 `FileImage`，`cacheWidth` 须与 `QuestionSlice` 两处一致：纸面 960、切片卡 440；注：`Image.file` 的真实解码在 fake zone 里等不到完成，不预热图一直是 0 尺寸，见 `p2_main_chain_test` 的同款注释）后断言 overlay 与纸面容器同宽、stem 框（overlay 左右各 inset 10px）不出图。
- Bug 2 放大查看：点图开对话框，断言对话框内 overlay 与纸面同宽（InteractiveViewer 带缩放，只断言相对关系）。
- Bug 3：断言整题框切片卡比图宽出的只是卡自身内边距 + 边框（≤25px，两侧各 ≤12px）。
- Bug 4：见上。

## 验证

- `flutter analyze`：0 问题（`dart format` 后曾剩 1 条 info：`_refresh` 里一行旧代码被格式化拆行后触发 `curly_braces_in_flow_control_structures`；顺手给它加了花括号，该行在本次动的文件内）。
- 新增回归测试：修前 Bug 2（两处）/ Bug 3 失败、Bug 4 通过；修后 4 项全过。
- 相关既有测试：`organize_page_test.dart` + `detail_page_test.dart` 50 项全过；`review_page_test.dart` + `wrongbook_page_test.dart` + `widgets_forward_test.dart` + `uikit_test.dart` 104 项全过。
- 全量测试：跑过一次（`flutter test`），4 项失败，**全部与本次改动无关，且单独重跑后通过**：
  - `collect_page_test.dart` 的 3 项 B2-6b（修框 overlay 高度 / 右键拖框 / 左键拖框）：失败时另一位工人正在并行改 `test/collect_page_test.dart`（该文件 11:38 仍在被改；其中一次重跑在加载阶段就编译失败）。三项单独重跑全部通过。我的改动未碰收集页修框编辑器（它不用 `QuestionRegionOverlays` 也不用放大查看对话框），不可能影响这三项。
  - `p05_image_pipeline_e2e_test.dart`（phase=write）：失败原因是未设 `LD_LIBRARY_PATH`，缺 onnxruntime 原生库跑不了真实推理（测试文件头注明的既有前置条件，与本次改动无关）；按文件头要求设好 `LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux` 后重跑通过（检出 16 框）。
  - 全量跑完后演示库被改动（md5 变为 `449ddd69…`，符合任务单提示的已知风险），已从协调员备份恢复，md5 核对一致 `8f7f9c64405dc6e484ac2bf8e5e1a807`。另：开工时我放在 `/tmp` 的备份中途消失了（`/tmp` 是易失的），恢复用的是工作区里的协调员备份；建议后续备份直接放工作区，不要放 `/tmp`。

## 需 Meng 决定的事 / 后续建议

1. **整理页叠加层是否改用库里真实的 Layer-2 框坐标**（`question_boxes`，页图相对坐标 → 按 Layer-1 整题框换算到题图坐标后画框；无真实框时回退到现在的推导示意框）？本次只修了“框不出图”，没换数据源。换数据源是产品行为变化（真实框位置 vs 现在写死的 34%/36%/42%），请 Meng 定。
2. `QmFoldSection` 的文档注释（“调用方……收起其他段”）与整理页独立折叠的实际行为不符，建议另行修正注释（不在本批分工内，未动）。
3. 附带说明：`dart format` 顺带规范化了本次动的两个 lib 文件的格式（工作树此前未格式化），功能 diff 见本报告“改动”一节；另修了一个 analyze info（一行旧代码加花括号）。
