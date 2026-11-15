# B3 追加项 1：整理页叠加层改用库里真实的 Layer-2 框坐标

工人：B3-overlay。工作树 `~/workspace/quiz-master2-UI`，分支 `ui-replication`。
未做 git 操作（不 commit、不 push、不 reset、不 checkout，未推代码）；
未动 `assets/models/`、未动 `test/fixtures/` 二进制；
未改 `lib/data/database.dart`、`lib/modules/collect/collect_page.dart`、
`lib/data/repository.dart`（读框走仓库已有的 `boxesForPageImage`）。

## 1. 改了什么

### `lib/widgets/widgets.dart`

- L29–35 `regionsOfQuestion` 文档注释：同步“叠加层已接线”的口径（函数
  本体未改）。
- L44–70 新增 `layer2BoxToSliceRect(QuestionBox layer1, QuestionBox layer2)`：
  页图坐标的 layer-2 框换算到整题切片坐标（0..1），见下 §2。layer-1 框
  无面积、或换算后无面积时返回 null（调用方回退示意框）。
- L71–97 新增 `realRegionRects(List<QuestionBox> boxes)`：从某题的全部框
  （layer 1 + layer 2）算出各区域在切片内的 0..1 矩形，键为 stem / option /
  figure。无 layer-1 框时返回空 Map；type 不是 stem/option/figure 的
  layer-2 行忽略；同区域多个框取列表第一个。
- L102–122 `QuestionRegionOverlays`：新增可选参数
  `realRects = const {}`（`Map<String, Rect>`，切片 0..1 坐标）；L133–141
  `region()` 改为接受示意框 `Rect fallback`，`realRects` 里有该区域时按
  真实框画（`left = rect.left * w` 等），没有时用原示意框。示意框几何
  （stem 上 34%、option 下 36%、figure 下 42% 居中 48% 宽）逐字未变。
- L808–842 `showQuestionZoomDialog` / `_ZoomDialog`：新增可选参数
  `realRegionRects = const {}`，直通放大浮层里的 `QuestionRegionOverlays`
 （L1052）；默认空，不影响其他调用方。

### `lib/modules/organize/organize_page.dart`

- L17–24 文件头注释：同步“叠加层已接线、是否显示仍由 `regionsOfQuestion`
  决定”的口径。
- L96–101 状态：新增 `Map<String, Rect> _realRegionRects`（当前题各区域
  的切片 0..1 矩形）。
- L219–242 `_loadForm()`：切题时先在 `setState` 里清掉上道题的真实框
  （防闪现旧框），再调 `_loadRealBoxes()`。`_loadForm` 是全部切题路径
  （`_refresh` / `_goTo` / 队列跳转 / 排序）的汇合点，故各路径都覆盖。
- L243–263 新增 `_loadRealBoxes()`：`pageImagePath` 为空（演示题 / 老题
  无页图）时不读库，直接留空；有页图时走仓库已有的
  `QuestionRepository.boxesForPageImage(pageImagePath)`（同页各题的 1 层 +
  2 层框），只取 `questionId == 当前题 id` 的行，用 `realRegionRects`
  换算；完成时校验 `mounted` 且仍是同一题（防切题竞态）。
- L787 `_paperImage`：放大浮层调用加 `realRegionRects: _realRegionRects`；
  L813 叠加层加 `realRects: _realRegionRects`。`_visibleRegions` 未动。
- 未改 `lib/data/database.dart`：读某题框本可用静态
  `boxesForQuestionFrom`，但仓库层没有对应的实例方法；复用仓库已有的
  `boxesForPageImage` + `questionId` 过滤即可，不必加新方法。
- 未改 `_slicesSection`（修框切片段）：本次只改叠加层渲染，各区域切片卡
  仍按 `regionsOfQuestion` 展示，与任务范围一致。

## 2. 坐标换算关系

- `QuestionBox` 的 x/y/w/h 是页图 0..1 坐标（`models.dart` L459–485 注释；
  `question_boxes` 表 CHECK 约束 0..1）。
- 切片就是页图按 layer-1 整题框裁出的图（`page_image_pipeline.cropBoxPng`
  用同一组 0..1 坐标按像素四舍五入裁剪）。
- 确认时框与页图在同一坐标系：`collect_page.dart` L356 / L376 / L1801 /
  L1855 在确认前对框调 `rotateBoxToRotatedPage`，切片由 `cropRotatedSlice`
  在烘焙旋转后的页图上用旋转后的框裁出；入库的框就是旋转后的框。
- 所以换算就是 layer-2 框在 layer-1 框内的相对位置：
  `x' = (x − lx) / lw`，`y' = (y − ly) / lh`，`w' = w / lw`，`h' = h / lh`；
  结果钳制进 0..1。叠加层渲染时再乘以叠加层像素宽高。
- 换算没有新定坐标系：与 `cropBoxPng` / 确认流程共用同一套页图坐标。

## 3. 回退规则

- 某区域无 layer-2 框、或换算后无面积、或整题无 layer-1 框、或本题
  `pageImagePath` 为空（不读库）：该区域画原示意框；各区域独立回退
  （有框的区域用真实框，无框的区域仍用示意框）。
- 同区域多个框时取列表第一个（`boxesForPageImage` 无 ORDER BY，行序即
  返回序）；见遗留问题 1。

## 4. 与 P1-1 降级的边界（红线）

- 是否显示区域仍只由 `regionsOfQuestion`（sliceText 推导）决定，
  `_visibleRegions` 与 `_regionToggles` 未动：真实题（空 `sliceText`）
  的 `visible` 为空，叠加层挂在树里但不画任何框，区域开关整行仍隐藏
  ——即使库里存有该题的 layer-2 真实框也不画（`_loadRealBoxes` 会读到
  框并算出矩形，但渲染门控在 `visible`，见测试“真实题即使库里有框”）。
- 本次改动只改变“画在哪”，不改变“画不画”；只影响仍显示区域的演示 /
  老题（有 `sliceText` 且库里有框的题）。

## 5. 测试

### 新增 `test/b3_overlay_layer2_test.dart`（14 个）

- `layer2BoxToSliceRect` 单元测试 3 个：基本换算
  （layer-1 (0.1,0.2,0.5,0.4) + layer-2 (0.2,0.3,0.1,0.1) →
  (0.2,0.25,0.2,0.25)）；部分落在整题框外钳制进 0..1；layer-1 无面积 /
  layer-2 完全在框外返回 null。
- `realRegionRects` 单元测试 3 个：layer-1 + stem/option 换算正确
  （stem (0.2,0.2,0.4,0.2) 经 layer-1 (0.1,0.1,0.8,0.8) →
  (0.125,0.125,0.5,0.25)，option → (0.125,0.625,0.5,0.25)）；无 layer-1
  框返回空；非 stem/option/figure 行忽略、同区域多框取第一个。
- `QuestionRegionOverlays` widget 测试 4 个（400×300 固定尺寸，断言区
  域标签相对叠加层原点的偏移，标签在框内左上 +4px）：有真实框时 stem
  标签在 (84,79) 而非示意 (14,14)；无真实框回退示意框（stem (14,14)，
  option (14,184)）；部分真实（stem 真实、option 示意）；`visible`
  为空时不画框（即使给了真实框）。
- 整理页接线测试 4 个（FakeRepo 覆盖 `boxesForPageImage`，不碰真实库；
  用 `tester.getSize` / `getTopLeft` 实测叠加层尺寸与偏移）：
  有真实框的老题——stem/option 标签偏移等于 0.125×叠加层尺寸 +4，
  且同页别题的框被 `questionId` 过滤；无真实框的老题回退示意框
  (14,14)；真实题（空 `sliceText`）即使库里有框仍无区域标签、无开关、
  无 Checkbox；放大浮层同样按真实框画（浮层纸面经 InteractiveViewer
  缩放约 1.32×，期望值用对话框内 QuestionSlice 的屏幕宽 / 布局宽实
  测缩放后换算）。

### 结果（均在本机跑过，未跑全量，全量由协调员统一跑）

| 文件 | 结果 |
|---|---|
| `test/b3_overlay_layer2_test.dart`（新） | 14/14 通过 |
| `test/organize_page_test.dart` | 26/26 通过 |
| `test/b3_p11_layer2_downgrade_test.dart` | 6/6 通过 |
| `test/b2_win11bug_organize_test.dart` | 4/4 通过 |
| `test/widgets_forward_test.dart` + `test/uikit_test.dart` | 36/36 通过 |
| `flutter analyze`（`lib/widgets/widgets.dart`、`lib/modules/organize/organize_page.dart`、`test/b3_overlay_layer2_test.dart`） | 0 问题 |

### 演示库

跑测试前已备份 `~/.local/share/quiz-master2/quiz-master2.db` 到
`~/workspace/demo-db-backup/quiz-master2.db.b3-overlay`。收尾核对 md5
仍为 `8f7f9c64405dc6e484ac2bf8e5e1a807`（与任务给出的值一致），未被测
试改写，无需恢复。测试用 FakeRepo，未打开真实库单例；`TMPDIR` 用
`~/workspace/.tmp-b3-overlay`，跑完已删除。

## 6. 遗留问题

1. 同区域多个 layer-2 框时取列表第一个；`boxesForPageImage` 无 ORDER BY，
   行序即返回序（通常是 rowid 序），同一区域画多框的场景未定义优先级。
   如需确定性语义（如取面积最大者），可另起一项。
2. 真实题即使库里有 layer-2 框，整理页仍不显示区域（P1-1 红线，有意
   为之）；若将来决定真实题也要显示真实框，只需改 `_visibleRegions` /
   `regionsOfQuestion` 的门控，渲染与读框链路已就绪。
3. 本次只改叠加层；修框切片段（`_slicesSection`）各区域切片卡仍按
   `regionsOfQuestion` 展示，未用真实框坐标裁剪，如需接线可另起一项。
4. 未在真机上验证：真实框坐标来自库里已存的手动框，本次测试用的都是
   FakeRepo 预置框；真实库里有手动 layer-2 框的题在 Win11 真机上的
   实际显示效果待复核。
