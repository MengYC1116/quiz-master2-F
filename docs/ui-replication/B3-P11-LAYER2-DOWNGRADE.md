# B3 P1-1 二层切片降级 + QuestionSlice errorBuilder + QmFoldSection 注释

工人：B3-UI。工作树 `~/workspace/quiz-master2-UI`，分支 `ui-replication`。
未做 git 操作（不 commit、不 push、不 reset、不 checkout，未推代码）；
未动 `assets/models/`、未动 `test/fixtures/` 二进制；
未改 `lib/data/database.dart`、`lib/modules/collect/collect_page.dart`。

## 1. P1-1 二层切片降级（Meng 已定：暂缓，不接线）

### 改了什么

- `lib/widgets/widgets.dart`
  - L23–35 `regionsOfQuestion`：`sliceText` 为空（`trim().isEmpty`）时返回空列表，不再从空文字推导假 region；非空时推导规则不变（stem 恒有；含 `（　）` / `______` 加 option；`chart` / `timeline` 加 figure）。文档注释同步说明降级口径：库里已存的手动二层框（`QuestionBox` layer=2）保留不动，不删数据、不改 schema，不接线到整理页叠加层。
  - L48–53 `QuestionRegionOverlays` 文档注释：补充“P1-1 降级后只对演示题 / 老题画框，真实题 `visible` 为空不画框；几何仍是 HTML 演示比例，不是真实框坐标”。
- `lib/modules/organize/organize_page.dart`
  - L17–21 文件头注释：改为“二层区域只对演示题 / 老题按题干文字推导；真实题无 region 开关，只留整题切片；已存手动二层框不接线”。
  - L712–724 `_leftPane`：`hasRegions = regionsOfQuestion(q).isNotEmpty`，无区域时开关整行隐藏（连同它前面的 10px 间距），只留整题切片 + 修框切片；有区域时布局与原来一致。
  - L755–757 `_paperImage` 注释：真实题的 `_visibleRegions` 为空，叠加层挂在树里但不画任何框（见下“有意保留”）。
  - L782–793 `_regionToggles`：`regions.isEmpty` 时返回 `SizedBox.shrink`（调用方已整行隐藏，这里是兜底）。
  - L844–846 `_slicesSection` 文档注释：补充“P1-1 降级后真实题的 `regionsOfQuestion` 为空，修框切片只剩「整题框切片」一张卡”。代码未改（原有 `hasText` 门控已只留整题卡）。

### 降级后的具体表现

- 真实题（空 `sliceText`）：整理页不显示 `stem 题干` / `option 选项` / `figure 插图` 开关，不显示“区域仅作辅助定位，整题图始终是主体”说明，不画任何区域虚线框；整题切片与「修框切片」段（仅「整题框切片」一张卡）正常显示；放大查看浮层同样不画框（`visibleRegions` 为空）。
- 演示题 / 老题（有 `sliceText`）：开关、高亮框、修框切片各子卡与原来一致。
- 库里已存的手动二层框：未做任何读写改动；`QuestionBox` 相关代码未碰。

### 有意保留（不是遗漏）

- `QuestionRegionOverlays` widget 在真实题时仍挂在树里（`Positioned.fill` + `IgnorePointer` 包裹），只是 `visible` 为空所以不画框。原因是 B2 的 Bug 2 回归测试按 widget 类型找叠加层（`find.byType(QuestionRegionOverlays)` 断言 1 个 / 放大后 2 个）；拆掉挂载会破坏该回归测试。已在 `_paperImage`（L755–757）写明。

## 2. QuestionSlice 的 Image.file 加 errorBuilder

### 改了什么

- `lib/widgets/widgets.dart`
  - L272–310 新增 `_missingImagePlaceholder(context, subject)`：把原来“文件缺失”分支的占位（学科图标 + `学科 · 题型` + 「图片缺失，可重新导入/重新框选」）抽成共用方法。
  - L332–333 `Image.file` 加 `errorBuilder`：解码失败时调用同一占位，不再显示 Flutter 的报错占位。
  - L340 原“文件缺失”分支改为调用 `_missingImagePlaceholder`，文案与样式与原来逐字一致（仅抽取，无行为变化）。
- 口径说明：与详情页图片加载失败“学科图标 + 题型文字”的处理同结构；解码失败复用的是本 widget 内已有的缺图分支，不是新造的文案。`failed` 分支（`imageFailed` 开关）的文案「整题图加载失败，先显示学科图标和题型，不留空白」未动，与缺图分支文案略有不同，见遗留问题。

### 降级后的具体表现

- 切片文件存在但内容损坏 / 非图片时，显示学科图标 + `学科 · 题型` + 「图片缺失，可重新导入/重新框选」；文件缺失时同一占位；有效切片正常显示图片。

## 3. QmFoldSection 注释改对

- `lib/widgets/uikit.dart` L1683–1689：只改文档注释，不改行为。
- 原注释称“调用方翻转该段的展开态并收起其他段”，与实际不符。核实了全部 5 处调用方：整理表单 / 详情三段 / 收集说明用每段独立布尔值，可多段同开；设置五组 / 学科管理四组用单个 open key（`_openGroup` / `_openSection`），只开一段。新注释：“各段独立展开 / 收起：本组件不做互斥，只按传入的 `expanded` 展示，点头部时调 `onToggle`，展开态由调用方各自维护；……互斥是调用方自己的选择，不是本组件的行为。”

## 测试

### 新增 / 改动的测试

- 新建 `test/b3_p11_layer2_downgrade_test.dart`（6 个）：
  - `regionsOfQuestion` 单元测试 3 个：空 `sliceText` → 空列表；仅空白字符 → 空列表；演示题推导不变（含填空标记 → stem+option；chart → stem+figure；function 无填空 → 仅 stem）。
  - `QuestionSlice errorBuilder` widget 测试 3 个：损坏的切片文件 → 显示「图片缺失，可重新导入/重新框选」+ `数学 · 材料题`，`takeException()` 为空；文件缺失 → 同一口径占位（对照）；有效切片（`test/fixtures/slice-narrow-500x120.png` 的副本）→ 显示 `Image`，不显示缺图占位。
  - 夹具处理：文件放进 `AppDatabase.testDataDirectory` 下的 `slices/`，`slicePath` 用相对路径（B3-P01 把 `resolveDataPath` 改为默认拒绝绝对路径后，另一工人已同步改过本文件与 B2 测试的夹具用法；本工人沿用了该改法，未改 `database.dart`）。
- `test/organize_page_test.dart` 追加 `P1-1 二层切片降级` 组（2 个）：
  - 真实题（空 `sliceText`，单题 FakeRepo）：无 region 开关文案、无说明文字、无 `Checkbox`；「修框切片」在，只剩「整题框切片」，无题干 / 选项 / 配图卡。
  - 演示题对照：`Checkbox` 2 个 + 说明文字 1 处；`stem 题干` / `option 选项` 各出现 2 次（开关标签 + 叠加层标签——初版断言写成各 1 次失败后据此修正）。

### 结果（均在本机跑过，未跑全量，全量由协调员统一跑）

| 文件 | 结果 |
|---|---|
| `test/b3_p11_layer2_downgrade_test.dart`（新） | 6/6 通过 |
| `test/organize_page_test.dart` | 26/26 通过（含新增 2 个） |
| `test/b2_win11bug_organize_test.dart`（Bug 2/3/4 回归） | 4/4 通过 |
| `test/uikit_test.dart` + `test/widgets_forward_test.dart` | 36/36 通过 |
| `test/detail_page_test.dart` + `test/wrongbook_page_test.dart`（QuestionSlice 其他调用方抽查） | 69/69 通过 |
| `flutter analyze`（5 个改动文件） | 0 问题 |
| `flutter analyze`（全仓） | 1 个 warning：`test/collect_page_test.dart:85` 未使用的 `boxPages` 参数——是收集工人的文件，不在本任务范围内，未动 |

### 演示库

跑测试前已备份 `~/.local/share/quiz-master2/quiz-master2.db` 到 `~/workspace/demo-db-backup/quiz-master2.db.b3-ui`。收尾核对 md5 仍为 `8f7f9c64405dc6e484ac2bf8e5e1a807`（与任务给出的值一致），未被测试改写，无需恢复。本次测试均用 FakeRepo 或临时 `testDataDirectory`，未打开真实库单例。

### 测试写法上的一点发现（已写入新测试文件注释）

定位耗时较久，结论：真实文件 IO（`createTemp` / `writeAsBytes` / `copy`）不能直接在 `testWidgets` 体里 await——体跑在 fake async zone 里，等不到完成会挂住；必须放 `setUp` / `setUpAll` / `runAsync` 里做。挂着待解码 `Image.file` 的 `pumpAndSettle` 也会等不到 settle 而挂住；新测试里解码推进用的是 `collect_page_test` 的 `tapConfirmAndWait` 同款做法（runAsync 内反复 pump + 200ms 真实延时），挂载留在 runAsync 外。

## 遗留问题

1. `CompactSliceThumb`（`lib/widgets/widgets.dart` 约 L475 起）的 `Image.file` 没有 `errorBuilder`，解码失败时仍会显示 Flutter 的报错占位。任务只要求改 `QuestionSlice`，此处未动；如需同口径处理可另起一项。
2. `QuestionSlice` 的 `failed` 分支文案（「整题图加载失败，先显示学科图标和题型，不留空白」）与缺图分支文案（「图片缺失，可重新导入/重新框选」）略有不同；本次解码失败复用缺图分支，未统一两处文案。
3. 全仓 `flutter analyze` 的 1 个 warning 在 `test/collect_page_test.dart:85`（另一工人的文件），未处理。
4. 交叉影响说明：工作期间同批另一工人（B3-P01）改了 `lib/data/database.dart` 的 `resolveDataPath`（绝对路径默认拒绝）并同步改了本人的新测试文件与 B2 测试的夹具用法；本人未改 `database.dart`，沿用了其改法。另，`MEMORY.md` 在工作期间新增一条“Push deferred（Meng, 2026-11-14）：Batch 1/2/3 + spine-fix 改动在最终自审前不 push”——本次本来就不 push，无影响。
