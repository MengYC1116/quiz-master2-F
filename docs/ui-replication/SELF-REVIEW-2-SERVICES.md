# 第二次自审 · 服务层 / 主题 / 组件（SELF-REVIEW-2-SERVICES）

- 范围：`lib/services/`（`zip_archive.dart`、`recheck_reminder.dart`；另按任务逐项核对 `import_service.dart`、`yolo_onnx_service.dart`、`page_image_pipeline.dart`、`pdf_render_service.dart` 内 Batch 5 改动点）、`lib/theme/app_theme.dart`、`lib/theme/design_tokens.dart`、`lib/widgets/uikit.dart`、`lib/widgets/widgets.dart`、`lib/widgets/app_shell.dart`、`lib/app.dart`、`lib/main.dart`。
- 依据：`docs/ui-replication/SELF-REVIEW.md`（逐条原文为准）、Batch 5 报告（`B5-SUMMARY.md`、`B5-P1-4-14-17.md`、`B5-P1-16.md`、`B5-P2-SERVICES.md`、`B5-P2-DATA.md`、`B5-P2-DOCS.md`）。
- 方式：只审、不改代码；读代码为主 + 针对性探针测试（跑完即删）+ 针对性单测复跑。未 commit、未推代码，未动 git 历史。
- 结论：**共 5 项：P0 × 0、P1 × 0、P2 × 5。** 其中 2 项是 Batch 5 修复引入的新回归（SR2-SERVICES-1 芯片点按死区、SR2-SERVICES-2 雾化漏了一个入口），1 项是 Batch 5 宣称修完但同类位置未修（SR2-SERVICES-3 修框编辑器 Codec 泄漏残留），1 项是修了一半且报告说法与代码不符（SR2-SERVICES-4 钳制语义分裂），1 项是 Batch 5 改政策后决定文档未同步（SR2-SERVICES-5）。
- 验证：`flutter analyze`（9 个范围文件）0 问题；复跑 `test/b5_p2_services_test.dart` 14/14、`test/b5_p2_data_test.dart` SR-P2-68 组 5/5、`test/yolo_onnx_service_test.dart` 25/25（含 SR-P1-16 回归测试，`LD_LIBRARY_PATH=onnxruntime-1.4.1/linux`）、`test/import_service_p1_fixes_test.dart` + `uikit_test.dart` + `theme_smoke_test.dart` + `widgets_forward_test.dart` 48/48、`test/p05_image_pipeline_test.dart` + `test/p3_backup_migration_test.dart` 40/40；演示库 md5 跑前后均为 `8f7f9c64405dc6e484ac2bf8e5e1a807`（v1、9 题），跑前已备份到 `~/workspace/demo-db-backup/quiz-master2.db`。临时探针 `test/zz_probe_sr2_test.dart` 已删除，不留痕。

---

## 问题

### SR2-SERVICES-1 · SR-P2-64 的修法把 `QmChip` 双区芯片的可点面积缩成了文字本身，内边距与两区之间的间隙点按无反应（Batch 5 新回归）

- 位置：`lib/widgets/uikit.dart:625-675`（`QmChip` 双区分支，`_QmPressable(childHandlesTap: true)` + 内层两个 `GestureDetector`）
- 现象：双区芯片（`onTap != null && onDelete != null`）现在只有标签文字与 `×` 字形本身能点；芯片的水平内边距（`deletableChipPaddingH = 12`）、垂直内边距（`deletableChipPaddingV = 4`）以及标签与 `×` 之间的 4px 间隙（`SizedBox(width: 4 * scale)`）点按后什么都不发生。更糟的是按压视觉仍会闪一下：外层 `_QmPressable` 的 `Listener`（`:243-252`，`childHandlesTap` 时驱动 `_pressed`）对全芯片的 pointer down 都有反应，用户看到芯片按下去了、却没有任何操作。
- 证据（临时探针，`test/zz_probe_sr2_test.dart`，已删）：
  - 点芯片左内边距（`rect.left + 3`，内边距区内）：`tapped=0 deleted=0`；
  - 点标签与 `×` 之间的间隙中点：`tapped=0 deleted=0`；
  - 对照点标签文字：`tapped=1 deleted=0`；对照点 `×`：`tapped=1 deleted=1`。
  - 结构原因：内层两个 `GestureDetector` 只包 `labelText(fg)` 与 `QmGlyph(close)` 两个子 widget（`:651-675`），`Container` 的 padding 与中间的 `SizedBox` 不在任何一个识别器内；外层 `_QmPressable` 在 `childHandlesTap` 时 `_tapEnabled` 为假（`:189`），不装 Tap 识别器。修前外层 `_QmPressable` 的 `GestureDetector(behavior: HitTestBehavior.opaque)` 覆盖整个芯片，点哪里都有效。
- 修的方向：把点按热区恢复到整个芯片，同时不恢复内外双识别器竞争。二选一：(a) 标签区的 `GestureDetector` 包住含左内边距的区域（padding 移进标签识别器内，`×` 识别器热区向外扩到右内边距），间隙归属标签区；或 (b) 外层 `_QmPressable` 保留一个“只在点按落点不在内层识别器内时才生效”的兜底（落点判断走 hit test，不进手势竞技场）。修后补测：点内边距与间隙的探针用例（本次探针的两个点位可直接转正为回归测试）。
- 严重度：**P2**（点文字仍可用，但芯片是小目标，用户自然点按位置大量落在内边距上；且“按下无反应 + 有按压闪烁”比纯死区更误导）。

### SR2-SERVICES-2 · SR-P2-66 的雾化漏了第三个入口：`subjectLabelColor` 在深色下仍直接返回库里存的饱和色

- 位置：`lib/widgets/widgets.dart:727-750`（`subjectLabelColor`），`return stored;` 在 `:737`
- 现象：Batch 5 只雾化了 `DesignTokens.subjectColor` / `subjectInk`（`design_tokens.dart:349,381` 走 `_darkStoredMist`），但 `widgets.dart` 里另有一份独立的学科色入口 `subjectLabelColor`，对非预设学科、有 `stored` 时不分亮深直接 `return stored`。深色下新学科在这些位置仍是饱和亮色——正是 SR-P2-66 原文描述的缺陷本身。
- 证据：
  - 代码：`:732-738` —— `if (stored != null && subjectId != 'math' && …) { return stored; }`，其后才判断 `dark`；其文档注释也仍写着旧口径（“深色只用冷雾色”与“新学科没有预设项，直接用库里存的轮换色”自相矛盾）。
  - 调用点（全部在深色可见位置）：`:311` `QuestionSlice` 加载失败占位 34px 学科图标；`:374` `_missingImagePlaceholder` 同款图标；`:617` `CompactSliceThumb` 失败占位 14px 图标；`:763` `SubjectLabel` 的 8px 圆点 + 学科名文字（文字色也是存色原值）。
  - 探针（临时测试，已删）：深色主题下 `SubjectLabel(subjectId: 'chemistry', color: #2E7CF6)` 的圆点色实测等于存色原值 `#2E7CF6`，而雾化值应为 `#7CAAF2`（`Color.lerp(#2E7CF6, #DCE3EC, 0.45)`）。
  - B5 的 SR-P2-66 测试（`test/b5_p2_services_test.dart` SR-P2-66 组）只断言了 `DesignTokens.subjectColor/subjectInk`，没有覆盖 `subjectLabelColor`，所以漏网。
- 修的方向：`subjectLabelColor` 的深色分支改走与 `subjectColor` 同一雾化（最好直接委托 `DesignTokens.subjectColor/subjectInk`，不要再造第三份“存色深色怎么处理”的规则）；同步改掉它头顶的文档注释。顺带：`lib/modules/subjects/subjects_page.dart:43` 的注释“亮/深两主题都直接用存色画圆点”也已过期（该页圆点实际走 `DesignTokens.subjectColor`，深色已雾化，见 `:615,635,708`），一并改掉——注释，不影响行为。
- 严重度：**P2**（与原 SR-P2-66 同级；只影响新学科、只在深色、只在占位图标与 `SubjectLabel` 位置；但它是“已修完”项的直接残留）。

### SR2-SERVICES-3 · SR-P2-69 的 Codec 泄漏在修框编辑器里仍活着：`_loadPageImageSize` 从不 dispose `Codec`

- 位置：`lib/modules/collect/box_editor.dart:421-444`（`_loadPageImageSize`；`instantiateImageCodec` 在 `:425`）
- 现象：该函数 `await ui.instantiateImageCodec(bytes)` 后只 `dispose()` 了解出的 `frame.image`，`codec` 本身在成功路径与异常路径上都未释放。每次切页都调一次（`initState` 与切页时重调），修框翻页越多漏得越多。Batch 5 的 SR-P2-69 只修了 `page_image_pipeline.dart` 的 `_decode` / `canDecodeImageBytes` 与 `yolo_onnx_service.dart` 的 `detectPage`，本处是全仓库第 4 个 `instantiateImageCodec` 调用点（`grep` 全仓库仅 4 处），是唯一漏网的。
- 证据：代码即证据——该函数体内无任何 `codec.dispose()`；对照已修的两处（`page_image_pipeline.dart:212-218` 的 `try/finally`、`yolo_onnx_service.dart:155-161` 的 `try/finally`）。另注：本文件属收集组范围，但任务 1 明确要求核对“每条解码路径”是否 dispose，故列在此处，请协调员转收集组修。
- 修的方向：与已修两处同款 `try/finally` 里 `codec.dispose()`（先取帧、再释放；`getNextFrame` 抛错时 `finally` 同样释放）。
- 严重度：**P2**（与原 SR-P2-69 同级；单次泄漏小，但修框是高频翻页操作）。

### SR2-SERVICES-4 · `clampToPage` 仍保留 SR-P2-70 的旧钳制模式，B5 报告“与 clampToPage 同一语义”的说法不成立

- 位置：`lib/services/yolo_onnx_service.dart:571` 起（`clampToPage`）；对照 `lib/services/page_image_pipeline.dart:60-75`（`rotateBoxToRotatedPage`，已修为区间求交）
- 现象：`rotateBoxToRotatedPage` 已修（`x=-0.1, w=0.5 → x=0, w=0.4`），但 `clampToPage` 的实现仍是“先钳左上角、宽只收到剩余空间”：`x = box.x.clamp(0,1)`，`maxW = 1 - x`，`w = box.w.clamp(0, maxW)`。输入 `x=-0.1, w=0.5` 时输出仍是 `x=0, w=0.5`——框整体右移且未缩宽，与 SR-P2-70 原文描述的缺陷逐字相同。B5 报告（`B5-P2-SERVICES.md` SR-P2-70 节）称新实现“与 `YoloOnnxService.clampToPage(minSize: false)` 同一语义”，实测不成立：同一输入，两函数输出的 `w` 分别是 0.4 与 0.5。
- 证据：
  - 既有测试把旧行为钉死了：`test/yolo_onnx_service_test.dart:81-88` 用例名“负坐标：左上角收到 0，尺寸不变”，断言 `box(-0.2, -0.1, 0.5, 0.5)` 钳制后 `w` 仍为 `0.5`。
  - 影响面不只理论：检测管线 `_toPageBox`（`yolo_onnx_service.dart` 内，`minSize: false`）与修框编辑器检测结果入库（`box_editor.dart:500`，`clampToPage(b, minSize: false)`）都走它；YOLO 框贴到页左/上边缘、letterbox 换算出轻微负坐标时，框会被整体平移且右/下沿超出真实检测框，溢出量有多大、框就偏多大。
  - 但注意：`clampToPage` 默认 `minSize: true` 的分支（编辑器手画/拖动用，`box_editor.dart:752,852,862,871,929,942,971,1119`）保留尺寸是有意的交互语义（框被拖出页边时不静默缩小、保持可抓取），其文档注释（“不把左上角收进来”一节）与测试用例是一致的——所以这不是无脑改成求交就能了事的项。
- 修的方向：需先定夺，再动手：(a) 只给检测路径（`minSize: false`）改成交集语义，编辑器路径保持现状，并把 `test/yolo_onnx_service_test.dart:81` 的用例按 `minSize` 分两组重写（`minSize: false` 时左溢出扣宽，默认时尺寸不变）；或 (b) 维持 `clampToPage` 现状，但把 B5 报告与 `page_image_pipeline.dart:63` 的“同一语义”注释改掉，写明两者有意不同。无论选哪条，`rotateBoxToRotatedPage` 本身不用再动。
- 严重度：**P2**（与原 SR-P2-70 同级；触发需框贴左/上边缘溢出，YOLO 输出多在页内，概率低；但报告说法错误会误导后续接手者按“同一语义”去复用）。

### SR2-SERVICES-5 · SR-P1-14 改政策后，决定文档仍写“超限只提示不硬拦”，与新代码直接矛盾

- 位置：`docs/decision-log.md:133`（D-15）；`docs/quiz-master2-mo-kuai-bian-jie-hua-fen.md:85`（§4.2）
- 现象：Batch 5 把图片 20MB 从“只提示”改成与 PDF 同款硬判（`import_service.dart:216` 注释“不再只提示不执行”，`enqueue` 复制前硬判），收集页横幅与 `oversizeHint` 文案已同步（标题“文件超过大小上限，导入会失败。”）。但两份决定性文档仍写旧政策：D-15“只收 PDF/JPG/PNG（PDF 50MB / 图片 20MB，超限只提示不硬拦）”；边界文档 §4.2“PDF 上限 50MB、图片上限 20MB，超限只提示不硬性拦截”。
- 证据：代码与横幅已是一致的硬判口径（见“已核实干净”SR-P1-14），两处文档行是全文 `grep "只提示|不硬拦|不硬性拦截"` 仅剩的与超限政策有关的旧表述；Batch 5 的 P1-14 报告未提及这两处。
- 修的方向：两处各改一行，改为硬判口径（PDF 50MB / 图片 20MB，超限进 failed 任务、不复制不渲染）。改文档即可，不动代码；属文档工人范围，请协调员转交（但漂移由本次代码改政策造成，记在本组报告里）。
- 严重度：**P2**（无用户可见影响；但 decision-log 是后续改动的依据，留着旧政策等于埋一个“把硬判当 bug 改回去”的坑）。

---

## SR-P2-66 裁决复核（单独一节）

**结论：协调员保留雾化做法的裁决成立，但 Batch 5 的修复不完整——裁决本身正确，执行漏了一个入口（见 SR2-SERVICES-2）。**

逐项核对：

1. **雾化 45% 是否真在代码里、作用在哪些组件上——属实。** `lib/theme/design_tokens.dart:365-366`：`_darkStoredMist` 为 `Color.lerp(stored, const Color(0xFFDCE3EC), 0.45)!`；`subjectColor`（`:349`）与 `subjectInk`（`:381`）的非预设学科深色分支都走它。经 `subjectColor` / `subjectInk` / `subjectSoft` 的调用点全部受益：左导航圆点（`app_shell.dart:528`）、学科管理行与圆点（`subjects_page.dart:615,635,708`）、首页学科卡标题/底色（`home_page.dart:644,646`）、复习页学科名（`review_page.dart:1100,1377`）、错题本紧凑行学科名（`wrongbook_list.dart:934`，此处硬编码亮色、因在浅色纸面上，见下）、`QmChip` 选中态填充（`uikit.dart:566,590`）。预设三科不受影响（分支先判断 `subjectId != 'math'/'english'/'politics'` 才走存色）。

2. **“15% 深底混色用在圆点/字色上会暗到看不清”是否属实——属实，且在全部 12 色轮换色上都成立。** 用 WCAG 相对亮度公式对深色底 `#262B33`（`surface`）实算：
   - `subjectSoft` 深色做法（`Color.lerp(#262B33, stored, 0.15)`）的对比度：12 色轮换色全部落在 **1.15–1.35:1** 之间（以 `#2E7CF6` 为例算出 `#273750`，对比度 1.18:1）——与底色几乎无差，作为圆点看不见、作为字色读不了。自审建议的字面做法若用在圆点/字色上确实不可行。
   - 雾化 45% 后的对比度：12 色全部落在 **5.75–8.56:1** 之间（`#2E7CF6 → #7CAAF2`，6.02:1），与预设三科深色雾色同一档（数学深色 `#87A9CC` 为 5.81:1），均超过正文 4.5:1 阈值。
   - 对照：存色原值 `#2E7CF6` 直接用在深底上对比度 3.61:1——看得见但低于正文阈值，雾化是改进而非多余。

3. **`subjectSoft` 深色分支是否确实未动——属实。** `design_tokens.dart:406` 仍为 `Color.lerp(const Color(0xFF262B33), stored, 0.15)!`，与自审原文一致。且该用法是合理的：`subjectSoft` 只做底色 tint（首页学科卡底等大块背景），文字走雾化后的 `subjectInk`，15% tint 做底色没有可读性问题；协调员“底色 tint 与圆点/字色是两回事”的区分成立。

4. **雾化做法与“深色只用冷雾色”是否一致，有无别的深色饱和色残留点——基本一致，但有一个残留点。** 经全仓库核查，除 `subjectLabelColor`（SR2-SERVICES-2）外，没有其他“存色直出深色”的位置：`review_page` / `wrongbook_list` / `app_shell` / `subjects_page` / `home_page` / `QmChip` 全部走 `subjectColor/subjectInk/subjectSoft`。另两处表面可疑点已排除：(a) `wrongbook_list.dart:934` 的 `subjectInk(..., Brightness.light, ...)` 是硬编码亮色，但该行在浅色纸面（深色下纸仍是 `#D8DCE2`）上，亮色字正确；(b) 错题本封面色（`CoverTokens` 7 预设）深色下仍是饱和色块，但封面是“书”的实物外观、属 D6 独立取值，不在 SR-P2-66 的学科色范围内。另：`subjects_page.dart:43` 的注释“亮/深两主题都直接用存色画圆点”已过期（见 SR2-SERVICES-2），只影响注释。

**裁决复核小结：雾化 45% 的做法正确，15% 混色不可行的论证有数据支撑，`subjectSoft` 未动正确；唯一缺口是 `subjectLabelColor` 这个第三入口未雾化，补上即完整。**

---

## 新测试质量

只列只测 happy path / 覆盖有缺口的（文件名 + 用例名）；覆盖扎实的测试见“已核实干净”。

- `test/b5_p2_services_test.dart` — “SR-P2-64：QmChip 双区点按只触发对应回调，各一次”：只点了标签文字中心与 `×` 字形中心（`tester.tap(find.text(...))`），没有点芯片内边距与两区之间的间隙——正是 SR2-SERVICES-1 死区的两个点位。修法引入的回归因此漏网。应补：点左内边距、点两区间隙的断言（本次探针的两个点位可直接转正）。
- `test/b5_p2_services_test.dart` — “SR-P2-66：新学科存色深色下雾化，亮色下原样，预设三科不动”：只断言了 `DesignTokens.subjectColor/subjectInk`，没有覆盖 `subjectLabelColor`（`SubjectLabel` 深色圆点色）——SR2-SERVICES-2 漏网的直接原因。应补：深色下 `SubjectLabel` 圆点色等于雾化值的 widget 断言。
- `test/b5_p2_services_test.dart` — “SR-P2-62：5MB 文件复制：进度 UPDATE ≤ 20 次，UI 回调仍逐次”：写库节流一侧是真凭据（触发器计数 ≤20，实测 16），但“UI 回调仍逐次”一侧只断言了 `reported.length > 2` 与 `last == 100`——3 个值也能通过，钉不住“每 1% 都回调”。应补：断言回调序列含 0→70 的连续百分比（或至少 `reported.length` 接近 70 + 渲染段）。
- `test/b5_p2_services_test.dart` — “SR-P2-69：canDecodeImageBytes 真图 true、假图 false；反复裁剪/旋转不因 dispose 坏掉”：只能钉住“释放后解码仍正常”这一回归面，native 泄漏本身在 `flutter_test` 里无法观测（B5 报告已承认）；且未覆盖第 4 条解码路径 `box_editor.dart` 的 `_loadPageImageSize`（SR2-SERVICES-3 的漏网点与此有关——该路径没有测试能触及）。属先天局限，记为局限而非测试作者的错。
- `test/b5_p2_services_test.dart` — “SR-P2-74：cacheWidth 乘 devicePixelRatio”：只在 `devicePixelRatio = 3.0` 下断言（960 / 384）；封顶值 2048 / 384 未被触发（`CompactSliceThumb` 在 dpr 3.0 时 384 恰好等于封顶，属巧合而非封顶测试）。应补：dpr 4.0+ 用例断言 `QuestionSlice` 封顶 2048、`CompactSliceThumb` 封顶 384。
- `test/b5_p2_services_test.dart` — “SR-P2-75：放大对话框点 ＋/－ 仍可用”：只断言对话框还在、无异常，没断言缩放真的变了（徽标 `%` 数或矩阵 scale），也测不出“build 内改状态”这一原缺陷。属 happy path；该缺陷类本质上靠代码走读（字段已删）保证，测试只能做烟囱。
- `test/import_service_p1_fixes_test.dart` — “SR-P1-14”组（21MB 图片失败、20MB 以内对照、`oversizeHint` 文案）：无恰好 20MB（`size == limit`）的边界用例；代码用 `size > limit`，恰好 20MB 应放行，但没有任何测试钉住这条边界。应补一个恰好 20MB 的图片用例。
- `test/b5_p2_data_test.dart` — “SR-P2-68 readZip 走中央目录”组（5 项）：负向覆盖较好（数据描述符 stored+deflate、纯目录包、名不一致、超大单条目预判、空 zip），缺口是 ZIP64 / 多盘 / EOCD 带注释的拒绝路径无用例；旧备份兼容（`buildZip` 产包读回）在本组内无用例——但 `test/p3_backup_migration_test.dart` 有多处 `buildZip → readZip` 往返断言，缺口已被别组合上，不单独立项。
- 未单测且已说明原因的（不记为质量问题）：SR-P2-67（弹框失败路径无法从公开 API 模拟，B5 报告已说明）、SR-P2-72（删死代码由 analyze + 既有测试覆盖）、SR-P2-73（decision-log 文字补记）、SR-P2-76（维持现状的决定）。

---

## 已核实干净（逐项一句话）

- **SR-P1-14**：`enqueue` 在复制前对 PDF 50MB / 图片 20MB 同款硬判（`import_service.dart:206-230`），超限进 failed、不复制不渲染；`oversizeHint` 与收集页横幅标题/正文均已统一为“导入会失败”口径（`collect_page.dart:841-847`），“仍然再导一份”按钮保留但正文已说明超限文件会记为失败任务。
- **SR-P1-16**：`_loadAttempted` 已删，`_ensureLoaded` 失败不锁死、成功后 `_loadOk` 缓存复用，并发加载共用 `_loadFuture`、失败后清空（`yolo_onnx_service.dart:119-132,181-207`）；回归测试 25/25 通过；真机上运行中补放模型文件是否立即生效仍待 Win11 实机确认（B5 报告已写明此局限）。
- **SR-P2-59**：`_importPdf` 的空间估算已改为 `used + total × 2MB`，不再加原文件（`import_service.dart:356-363` 注释写明原因）；稀疏文件顶到距上限 5MB 的边界测试通过。
- **SR-P2-60**：任务 id 已加 6 位随机段（`import_service.dart:197-198`）；收集页同款位置也已修（`collect_page.dart:527-528,602` 的 `task-$ts-$rnd-$p-$i` 与 `:350` 的 `newEntityId('task')`），B5 报告的遗留点 1 已过期。
- **SR-P2-61**：图片先经 `canDecodeImageBytes` 校验，解不开进 failed 并删目录（`import_service.dart:300-314`）；读盘/写盘等原因不明的失败仍保留旧降级，注释已写清区分；`.txt` 改 `.jpg` 与真 PNG 换后缀两组对照测试通过。
- **SR-P2-62**：复制进度写库节流到每 5 个百分点一次（`lastDbPct`，`import_service.dart:263-279`），`onProgress` 仍逐次；触发器计数实测 16 次写库（≤20）。
- **SR-P2-63**：`QmSegmented` 外层 `Opacity` 已删，只剩每段 `_QmPressable` 的一层 0.45（`uikit.dart:1105-1110`）；禁用态 2 选项恰好 2 个 `Opacity(0.45)` 的测试通过。
- **SR-P2-65**：`AppTheme._build` 的 `buttonPadding` 已改用 token 的 20/9（`app_theme.dart:119-125`），`FilledButton` / `OutlinedButton` / `TextButton` 三者共用；`QmButton` 本身也用同一 token（`uikit.dart:372-381`）。
- **SR-P2-67**：`_maybeShowRecheckReminder` 已改为先 `showDialog`、返回后再写“今天已提醒”，弹框抛错直接返回不写日期（`app.dart:171-214`）；`_reminderChecked` 的一轮一次语义不受影响。
- **SR-P2-68**：`readZip` 已改走中央目录（EOCD 定位 → 逐项校验条目数/偏移/名/方法/尺寸，`zip_archive.dart:230-360`），flag bit 3 的数据描述符按中央目录尺寸读并跳过，解压前用中央目录 `rawSize` 预判上限，无文件条目（空 zip / 只含目录条目）抛错；5 项新测试通过；旧备份兼容由 `p3_backup_migration_test.dart` 的多处 `buildZip → readZip` 往返断言覆盖。
- **SR-P2-69（服务层路径）**：`page_image_pipeline.dart` 的 `_decode`（`:212-218`）与 `canDecodeImageBytes`（`:225-235`）、`yolo_onnx_service.dart` 的 `detectPage`（`:155-161`）均已 `try/finally` dispose `Codec`；20 次反复裁剪/旋转测试通过；唯一漏网在收集组文件，见 SR2-SERVICES-3。
- **SR-P2-70（`rotateBoxToRotatedPage` 本身）**：已改为区间求交（`page_image_pipeline.dart:65-69`），左/右/上/下溢出与完全在页外、旋转后溢出、页内不动共 8 组断言通过；同名函数的兄弟 `clampToPage` 仍有旧模式，见 SR2-SERVICES-4。
- **SR-P2-71**：YOLO 报告 §2/§8 已更新为“失败不回占位框、返回空框 + `usedFallback: true`”，只需第 1 层模型（`YOLO-INTEGRATION-REPORT.md:59-60,198,205` 与 §8 第 2 条）；§6 的 674/674 是明确标注“Batch 5 第四阶段结束时”的快照，非实时总数。
- **SR-P2-72**：`ImportService.isAllowed`、`ScaledTokens.s()`、`YoloOnnxService.modelAsset` 已删（全仓库 grep 零引用）；`renderPagePng` 已标 `@visibleForTesting` + 仅测试用注释（`pdf_render_service.dart:189-192`）；第 2 层 5 个常量已集中标注“暂缓、再接入时启用”且 `crossClassIouThreshold` 在定义与传参两处注明单类时是空操作；`_crossClassNms` 已直接复用 `_nms`。
- **SR-P2-73**：D-11 已补记三档字号覆盖系统缩放（`decision-log.md` D-11 末尾，2026-11-15）；`app.dart:267` 仍是唯一的 `TextScaler.linear(scale)`，`qmScaleOf` 只读该因子（`uikit.dart:39-40`）；范围文件内无任何 `fontSize * scale` 的二次缩放。
- **SR-P2-74**：两处 `cacheWidth` 均已乘 `devicePixelRatio` 并封顶（`widgets.dart:419-424` 上限 2048、`widgets.dart:644-649` 上限 384）；dpr 3.0 下 960 / 384 的测试通过。
- **SR-P2-75**：`_dialogScale` 字段与 build 内赋值已删，`_multiply` 改用局部变量现取 `qmScaleOf(context)`（`widgets.dart:904-914`）；点 ＋/－ 对话框仍在的测试通过。
- **SR-P2-76**：同步文件 IO 维持现状的决定与依据已在 `import_service.dart:76-84`（`pageImageRelativeForTask`）写明注释；`yolo_onnx_service.dart:134-135` 原有同款注释未动；`widgets.dart` 三处 `existsSync`（`:413,595,638`）按 B5 报告未加注释（共享文件边界，决定已记在 B5 报告里）；行为无变化。
- **SR-P2-77**：产品代码未动——`lib/` 内无任何 `Timeout(`，5 分钟超时只加在 `test/pdf_render_service_test.dart`（13 处）与 `test/yolo_onnx_service_test.dart`（冒烟组 4 处）；两文件单文件串行复跑全过（PDF 13/13、YOLO 25/25）。
