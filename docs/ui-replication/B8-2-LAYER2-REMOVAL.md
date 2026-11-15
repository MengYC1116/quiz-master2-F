# B8-2 — 二层模型移除（内框模式删除）

- **批次**：第八批第 2 项
- **日期**：2026-11-15
- **决定**：Meng（截图 `image-91.png`、`image-92.png`）
- **分支**：`ui-replication`（工作树 `~/workspace/quiz-master2-UI`，不提交、不推送）
- **结论**：`flutter analyze` 0 问题；全量测试 **849/849 通过**（EXIT=0，
  2026-11-15 08:23–08:29 UTC 串行跑，日志 `~/workspace/b8-2-full-after.log`）。

## 决定

没有第二层模型了。修框编辑器里的内框模式横幅、“题级框 4”标签、
“这个框是？”里的 stem / option / figure 类型选择全部删除；
画框直接默认题级框，不再选二层模型的框。第三批（B3/P1-1）曾特意保留的
手动二层框与整理页真实二层坐标叠加层，这次按 Meng 新决定一并去掉。
推翻 `docs/decision-log.md` D-23 里“第 2 层的数据模型与界面不动”与
“没有模型时用户仍可手动框 stem / option / figure”，新记 D-24。

## 删了哪些（lib/）

| 文件 | 删除内容 |
| --- | --- |
| `lib/modules/collect/box_editor.dart`（2360 → 1662 行） | `BoxEditorResult.inners` / `standaloneInner`、`initialInners` / `initialStandalone` 入参、`normalizeBoxEditorInputs`、`_inners` / `_standaloneInner` / `_innerModeBoxId` / `_selectedInnerId` / `_pendingInner` 状态、`_enterInnerMode` / `_exitInnerMode`、`_clampInner`、`_confirmPendingType`、`_typeMenu`、`_regionColor` / `_regionLabel`、内框模式横幅/帮助/工具栏/底部提示文案、画布与 `_boxView` / `_boxBody` / `_replaceBox` / `_deleteSelected` / `_rotatePage` / `_restoreAutoBoxes` / `_restoreAutoBoxForRework` 里的内框分支（含 SR-P2-20 / SR3-14 内框跟随块）、双击进内框与 Esc 退出；`collect_widgets.dart` 与 `flutter/services.dart` import。画框改为 `_onDrawEnd` 直接落成题级框（layer 1，type `question`）。另删未用的 `_focusNode`。 |
| `lib/services/yolo_onnx_service.dart` | `intraModelAsset`、`intraInputSize`、`intraConfThreshold`、`intraClassTypes`、`groupInners`、`YoloDetectStats.layer2Count`；类注释重写（重接入点只剩开关 + 占位）。`crossClassIouThreshold` 保留（通用，第 1 层解码也在用）。 |
| `lib/widgets/widgets.dart` | `regionsOfQuestion`、`layer2BoxToSliceRect`、`realRegionRects`、`QuestionRegionOverlays`、`_DashedRegionPainter`；`showQuestionZoomDialog` / `_ZoomDialog` 去掉 `visibleRegions` / `realRegionRects` 入参与放大浮层里的叠加层。 |
| `lib/modules/organize/organize_page.dart` | `_showStem` / `_showOption` / `_showFigure`、`_realRegionRects`、`_visibleRegions`、`_loadRealBoxes`、`_regionToggles`、区域切片卡（`_optionBody`、`_figureBody`、`_FigureMiniPainter`）；`_slicesSection` 只留“整题框切片”卡；`_paperImage` 只返回切片（无叠加层 Stack）；`_sliceTextBody` 去掉 `withFigureNote` 入参。 |
| `lib/modules/collect/collect_page.dart` | `onSaveDraft` 去掉 inners / standalone；`_confirmSplit` 去掉 layer-1 过滤、inners 挂接、SR2-4 独立内框归属循环（歧义/太远计数与提示文案一并去掉）；保留任务参数去掉 `retainedInners` / `retainedStandaloneInner`；删 `_innerPage`、`_nearestLayer1Box`、`_intersectionArea`。 |
| `lib/modules/detail/question_detail_page.dart` | `_reworkBoxes` 不再拆/读 inners / standalone；`replaceQuestionBoxesAndSlice` 只传 `newLayer1`；详情提示“二层小框不在图上标”改写。 |
| `lib/models/models.dart` | `QuestionBox` 文档重写（无二层描述）；type 注释改为“question；旧行可能取历史值（表 CHECK 约束为准）”。 |
| `lib/data/db_collect.dart` / `lib/data/database.dart` / `lib/data/repository.dart` | `saveDraftBoxesInto` / `confirmSplitInto`（及包装）去掉 `inners` / `standaloneInner` / `retainedInners` / `retainedStandaloneInner` 入参；删 `_innerKeyPage`；文档更新。 |
| `lib/theme/design_tokens.dart` | `AppPalette.stem` / `option` / `figure` 字段删除（浅色 + 深色取值 + 构造入参）。 |
| `lib/theme/app_theme.dart` | token 列表注释里的 `--stem` / `--option` / `--figure` 删除（`_CompanionPainter` 的 `stemPaint` 是植物嫩芽，与二层无关，保留）。 |
| `lib/modules/collect/collect_widgets.dart` | 头注释去二层化（`DashedDropPainter` 仍被拖放区使用，保留）。 |

**未动（有意保留的惰性管线）**：`question_boxes.parent_box_id` 列与
`QuestionBox.parentBoxId` 字段、`db_codec.dart` 的读写（Schema 冻结）；
`db_collect.dart` `_deleteBoxesForQuestionTxn` 仍删指向该题框的旧
`parent_box_id` 行（孤儿清理）；详情页 `b.layer == 1` 读保护
（`question_detail_page.dart:219,399,402`）；`box_editor.dart`
加载/检测过滤（丢弃旧的非 layer-1 行）；`page_image_pipeline.dart:72`
字段拷贝。以上只处理已入库的旧行，不产生新二层框。

## 删了哪些（test/）

整文件删除（纯二层测试，共 33 个测试，计数按 622b6b6）：

- `test/b3_overlay_layer2_test.dart`（14 个）
- `test/b3_p11_layer2_downgrade_test.dart`（8 个）
- `test/b5_p1_256_test.dart`（11 个）

逐文件改动（共删 20 个测试，其余改写）：

| 文件 | 删除的测试 | 改写 |
| --- | --- | --- |
| `test/collect_page_test.dart` | ‘双击题级框进内框模式，Esc 退出’、‘内框模式三个默认内框全部落在画布可视区内’、SR2-4 组（1 个）、SR3-12 组（3 个） | ‘空白处画新框’改名并改为直接成题级框断言（两处菜单块删掉）；‘画出的框与原框重叠时确认被拦下’删菜单点按；B2-6b 三测删菜单/内框段，B3 测改按相对画布偏移比原框位置；FakeRepo 的 `saveDraftBoxes` / `confirmSplit` 覆盖去掉 inners / standalone 入参与字段 |
| `test/b5_p2_collect_test.dart` | SR-P2-23/24 组（3 个）、SR-P2-18 组（1 个）、SR-P2-19 首测（1 个）、SR3-14 组（1 个）、SR-P2-21 组（1 个） | `_openEditorDialog` 去掉 `initialInners` / `initialStandalone`；删 `_doubleTapBox`、`_clickMouseLeft` 两个 helper；SR-P2-20 两测去掉 inners 与跟随断言（只断言题级框坐标）；SR2-21 测把第 2 页内框换成手画题级框；SR-P2-32 测重写为“删框后右键拖画新框不崩”；SR-P2-25 测改名（旧草稿框夹具保留）；`_CollectFakeRepo` 覆盖签名同步 |
| `test/b5_p2_services_test.dart` | SR2-24 组（2 个） | 文件头注释去掉 SR2-24 一行 |
| `test/b2_win11bug_organize_test.dart` | Bug 2 组（2 个，叠加层几何断言） | 文件头 Bug 2 说明改为 B8-2 已删注记；`_realSliceQuestion` 注释去掉“区域只剩 stem” |
| `test/organize_page_test.dart` | ‘高亮开关：关掉 stem’、P1-1 组第 2 测（演示题 region 开关对照） | ‘修框切片默认展开’改为只有整题一张卡；P1-1 组改名‘二层切片已移除（B8-2）’，第 1 测保留（断言无 region 开关、只留整题切片） |
| `test/yolo_onnx_service_test.dart` | `groupInners` 组（1 个） | — |
| `test/b5_p2_data_test.dart` | — | 3 处 `saveDraftBoxesInto` 调用去掉 `inners` / `standaloneInner` 入参 |
| `test/p2_main_chain_test.dart` | — | ‘草稿作用域’测去掉内框夹具与 inners 入参并改名；‘确认拆题四步同事务’测去掉 inners 入参 |
| `test/theme_smoke_test.dart` | — | 两处 token 测试去掉 `palette.stem` / `option` / `figure` 断言（6 行） |
| `test/detail_page_test.dart` | — | 重框测去掉 `q1-stem` 夹具框，注释“只替换了目标题的题级框” |

另修：`test/organize_page_test.dart` 补回 P1-1 组删测时误删的组闭合
`});`；删三处因此未用的 import（`b2_win11bug_organize_test.dart` 与
`b5_p2_collect_test.dart` 的 `widgets.dart`、`collect_page_test.dart`
的 `flutter/services.dart`）。

## 删了哪些（docs/，实时文档）

- `docs/代码地图.md`：各段二层描述改为“已移除（B8-2）”并指向第 8 节；
  `question_boxes` 表行注明 layer 旧行与 CHECK 约束现状；YOLO 第 8 节
  标题改为“第 2 层已移除（重接入点）”，只留一处重接入点说明；
  测试文件列表去掉已删的 `test/b5_p1_256_test.dart`。
- `docs/decision-log.md`：追加 `D-24 — 二层模型整个移除（2026-11-15，Meng 定）`；
  旧 D-23 条目是历史记录，不改。
- `docs/CODEBUDDY.md`：第三批关键行为一段去掉 P1-1 与叠加层行，
  改记 B8-2 移除与两处重接入点。
- `docs/quiz-master2-mo-kuai-bian-jie-hua-fen.md`：4.2“两层框”段改为
  “整题框”段；4.2/4.3 的 OCR 与整题图查看段去掉二层描述；4.3“二层切片
  暂缓”改为“已随二层模型移除”。
- **历史报告不动**：`docs/ui-replication/` 下的批次报告（B3-P11、
  B3-OVERLAY-LAYER2、R 系列、SELF-REVIEW-* 等）是 dated 记录，
  不改写；其中的二层描述是当时的事实。

## 保留的三处接口（一个不多）

1. **`lib/services/yolo_onnx_service.dart`** — `intraEnabled = false`
   开关（:57）+ `_detectIntra` 占位（:340，恒返回 `[]`；`_detect`
   :320 仍调用它，开关关着时走空分支）。类注释 :38 与方法注释 :329–334
   说明再接入步骤（模型放回 `assets/models/intra/`、pubspec 声明加回、
   开关改 true、按注释实现本方法）。
2. **`question_boxes` 表（含 `layer` 列）** — Schema 一动不动：
   `lib/data/db_schema.dart:192` 的 CHECK 约束
   `type IN ('question', 'stem', 'option', 'figure')` 原样保留；
   库里旧的 layer-2 行保留不动，编辑器读到时直接丢弃。
3. **`docs/代码地图.md` 第 8 节** — 一处重接入点说明（标题
   “YOLO 第 1 层是真模型，第 2 层已移除（重接入点）”，:1152–1172）：
   模型路径、pubspec 声明、开关、stub 实现步骤与“两个模型文件名相同、
   必须放不同文件夹”。

## grep 验证

lib/（`innerBox|内框|二层|layer 2|'stem'|'option'|'figure'|groupInners|
realRegionRects|QuestionRegionOverlays|regionsOfQuestion|layer2BoxToSliceRect|
standaloneInner|initialInners|initialStandalone|_detectIntra|intraEnabled`）：

- 只剩 `yolo_onnx_service.dart`（允许处 1：开关、占位与注释，:38、:56–57、
  :319–320、:329、:334、:340、:344）与 `db_schema.dart:192`（允许处 2：
  CHECK 约束原文）。
- `lib/modules/wrongbook/wrongbook_cover.dart:171` 与
  `wrongbook_shelf.dart:257,413` 的“虚线内框”是书封装饰内边框，
  与二层无关，未动（第 8 项的文件，不碰）。
- 其余 `.layer` 引用只剩惰性管线（见上“未动”一段）；`option` /
  `options` 通用词（`QmSegmentOption`、设置分段选项等）保留；
  `stemPaint`（小伙伴画笔）保留。

test/（同上关键词 + `pending-type` / `这个框是？`）：

- `collect_page_test.dart` 与 `b5_p2_collect_test.dart` 里的“这个框是？”
  只剩 `findsNothing` 断言（断言菜单不再出现），无 `pending-type-*` 引用。
- `organize_page_test.dart` P1-1 组：第 1 测用 `findsNothing` 断言
  ‘stem 题干’ / ‘option 选项’ / ‘figure 插图’ 不出现；组名含“二层切片
  已移除（B8-2）”注记。
- `wrongbook_page_test.dart:496` 封面绘制注释“虚线内框”是装饰描述，未动。
- 有意保留的数据层夹具（Schema 级测试，非功能测试）：`p1_schema_backup_test.dart`
  （CHECK 文本断言与 layer-2 值行存取）、`b5_p2_data_test.dart:164–166,853–856`
  （删学科清草稿与排序夹具；同题挂多个 layer-1 框会违反“每题一框”
  部分唯一索引，故排序夹具仍用 layer-2 行）、`p2_main_chain_test.dart:258,266`
  （‘多题页面重框’夹具，同理）、`b5_p2_collect_test.dart:585–587`
  （SR-P2-25 的旧草稿框夹具：旧行仍算“已有草稿”）。

docs/（实时文档）：`docs/代码地图.md` 只剩一处重接入点说明（第 8 节），
其余段落只写“已移除（B8-2）”事实并指向第 8 节；
`docs/decision-log.md` 的 D-23 是历史条目（不改），新决定记 D-24；
历史报告（`docs/ui-replication/` 批次报告）不改写。

## 测试结果

- `flutter analyze`：**0 问题**（末次复核 2026-11-15 08:23 UTC；中间曾出现
  6 个问题：`organize_page_test.dart` 删测时误删组闭合 `});` 致语法错
  3 个、两处未用 import、一个多余 import，均已修）。
- 全量测试（`flutter test --concurrency=1`，`LD_LIBRARY_PATH` 指到
  onnxruntime 1.4.1，跑前 live 库已是 v1、跑完从 canonical 备份恢复并
  核对 md5，见下）：
  - **最终：849/849 通过，EXIT=0**（2026-11-15 08:23–08:29 UTC，
    无其他工人测试进程并行、analyze 0 问题时起跑；日志
    `~/workspace/b8-2-full-after.log`，`[E]` 0 行）。
  - 中间跑（2026-11-15 ~07:17 UTC 起跑）：+841 -4。4 个失败里 2 个是
    我的改动引入的，已修好（见下）；另 2 个与我无关：
    `SR-P2-59` 报 `libsqlite3.so` 原生库缺失（环境/并行跑 build 目录
    争用所致，最终跑中通过）、`b8_1_debug_probe_test.dart` 加载失败
    （第 1 项工人中途删了该探针文件）。53 个删除测试的算术：
    879 − 33（整文件）− 20（逐个删除）= 826；845（中间跑总数）与 849
    （最终跑总数）的差额是其他并行工人新增的测试。
  - 两个引入失败的修复（均已在最终跑中通过）：
    1. `SR-P2-25`（只有旧草稿框的任务不警告）：我误删了
       `collect_page.dart` `_load` 里 `boxedPages` 的
       `if (b.layer == 1)` 过滤，导致旧的 layer-2 行被误算为“已框页”。
       已恢复该过滤并加注释（只有 1 层框才算框了该页；旧 layer-2 行
       编辑器读到就丢）。`hasAnyDraftBox` 仍按“任意已存框都算”，不动。
    2. `B3 右键起点在框上画新框`（原框像素偏移断言失败）：重叠警告横幅
       出现后画布重排，像素坐标会变；改为按页内归一化坐标比对
       （`editorPageMetrics` 换算，容差 0.005）。
  - 另有一次复测（3 个文件）被虚拟机重启打断（见遗留），其 analyze
    部分已过 0 问题；三文件结果以最终全量跑为准。

## 遗留

- **基线跑被污染**：基线全量跑（`proc_1fcaf4a69578`，日志在 /tmp，已随
  重启丢失）进行中时，我删了三个测试文件，跑到 +599 -22 时撞上已删的
  `b3_overlay_layer2_test.dart`（加载失败），该跑已按 PID 杀掉；
  Batch 7 推送态 879/879 仍是有效基线（远端 head `622b6b6`）。
  本次删除共 53 个测试（整文件 33 个 + 逐个删除 20 个），
  预期 879 − 53 = **826**，再加其他并行工人新增的测试文件
  （如第 1 项的 `s8b2_subject_sync_test.dart` 等；最终跑总数 849）。
- **虚拟机重启**：2026-11-15 ~07:59 UTC 虚拟机重启（uptime 重置为 1 分钟），
  /tmp 全部日志丢失、三文件复测被 SIGTERM 打断（其 analyze 部分已过
  0 问题）；工作区文件未丢。重启后第 7 项的 detail 文件一度报 12 个
  analyze 错误（`DetailStyle` 未定义），后由该工人修好；最终全量跑在
  analyze 0 问题、无其他测试进程时起跑。
- **演示库**：标准演示库是 v1（`~/workspace/demo-db-backup/quiz-master2.db`，
  md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`，`user_version` 1，9 道题）。
  中间 live 库一度被改写为 v2（md5 `78b8661e`）；最终跑前后 live 库均已
  恢复为 v1 并核对 md5（跑后 `user_version` 1、9 道题）。备份/恢复一律用
  该 canonical v1 备份文件，不拿 live 文件当备份。
- **Win11 真机复核仍待**：本批只改代码与测试；修框编辑器交互
  （第 3/4/5 项）与整理页手风琴（第 6 项）是其他工人的文件，未碰。
- **第 2 层切片未来再说**：按 Meng 决定，重接入只走 §6 三处接口，
  不另开 v3。
