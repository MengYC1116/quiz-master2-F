# Batch 5 第五阶段 P2 — 服务层 / 组件 / 主题（B5-P2-SERVICES）

- 工作树：`~/workspace/quiz-master2-UI`，分支 `ui-replication`
- 范围：SR-P2-59、60、61、62、63、64、65、66、67、69、70、72、73、74、75、76、77（17 项；SR-P2-68 zip 与 SR-P2-71 YOLO 报告不在本组）
- 依据：`docs/ui-replication/SELF-REVIEW.md`（逐条原文为准）
- 状态：全部 17 项已处理（15 项改代码、2 项“维持现状并记入决定”）；未 commit、未推代码，未动 git 历史
- 验证：新测试 14/14；既有针对性测试 111 通过、2 跳过（均为 P05 原有跳过）；`flutter analyze` 0 问题；演示库 md5 未变

## 逐项结果

### SR-P2-59 `_importPdf` 存储估算把原文件算了两次
- 改动：`lib/services/import_service.dart`（`_importPdf` 的空间检查）。原文件在进 `_importPdf` 之前已复制进库，`storageUsageBytes()` 的 `used` 里已含它；估算从 `used + fileSize + total × 2MB` 改为 `used + total × estimatedBytesPerRenderedPage`，并在注释里写明不再加原文件的原因。
- 测试：新测试用稀疏填充文件把 `imports/` 占用顶到距 2GB 上限 5MB，再导一个 2MB 的假引擎 PDF——旧算法会误拒（`used + fileSize + 2MB = 2GB+1MB`），新算法放行进 `needBox`，断言通过。

### SR-P2-60 任务 id 是“毫秒时间戳 + 批内序号”，同毫秒可能撞 id
- 改动：`lib/services/import_service.dart`。id 从 `task-<ms>-<i>` 改为 `task-<ms>-<i>-<6 位随机数>`（类级 `static final _idRandom = math.Random()`）。
- 测试：同一文件连续两次 `enqueue`（跨批重导，允许），两个任务 id 不同、都进 `needBox`；同批两次选同一文件仍只建一个任务（SR-P1-17 去重不变）。

### SR-P2-61 图片解码失败时静默按原图进 `needBox`
- 改动：`lib/services/import_service.dart` 的 EXIF 分支 + `lib/services/page_image_pipeline.dart` 新增 `canDecodeImageBytes()`。读盘后先校验能否解出首帧：解不开 → 任务直接失败，提示“这张图片打不开，请确认文件是完好的图片再导入”，并删任务目录；读不到 / 写盘等原因不明的失败仍保留旧降级（修框时按原图走），`catch` 注释已改写说明这一区分。
- 测试：`.txt` 改 `.jpg` → `failed`、错误含“打不开”、目录已删；真 PNG 换 `.jpg` 后缀 → 仍进 `needBox`。

### SR-P2-62 复制进度每次百分比变化都写一次库
- 改动：`lib/services/import_service.dart` 复制循环。`onProgress` 回调保持逐次；写库节流到变化 ≥ 5 个百分点时一次（`lastDbPct`，0→70% 约 15 次写库，原来约 70 次）。收尾的 `needBox` / `failed` 行仍由 `upsertCollectTask` 写，不受影响。
- 测试：触发器统计 `AFTER UPDATE OF progress`：5MB 文件复制，进度 UPDATE ≤ 20 次（实测 16 次：复制 15 次 + 渲染 1 次），且 `onProgress` 仍逐次报到 100。

### SR-P2-63 `QmSegmented` 禁用态双重 0.45 透明度
- 改动：`lib/widgets/uikit.dart`。删掉 `QmSegmented.build` 末尾外层的 `Opacity(0.45)`，只留每段 `_QmPressable` 的一层 0.45（与 HTML `.btn:disabled{opacity:.45}` 一致）。
- 测试：禁用态 2 个选项 → `Opacity` 恰好 2 个、值全为 0.45（旧实现会多出外层 1 个）。

### SR-P2-64 `QmChip` 可删除 + 可点双区时内外两层 Tap 识别器竞争
- 改动：`lib/widgets/uikit.dart`。`_QmPressable` 新增 `childHandlesTap`：为真时本层不装 Tap 识别器（不进手势竞技场），点按全由内层两个 `GestureDetector` 承担；悬停/聚焦/按压视觉仍保留（按压态改由 `Listener` 驱动，`Listener` 不参与手势裁决）；键盘 Enter/空格与无障碍点按仍走外层的 `onTap`（主操作），不丢键盘激活。`QmChip` 双区时传 `onTap` + `childHandlesTap: true`；单区行为不变。
- 测试：双区芯片点片身 → `onTap` 1 次、`onDelete` 0 次；点 `×` → `onDelete` 1 次、`onTap` 仍为 1 次。

### SR-P2-65 `AppTheme` 主题按钮垂直内边距 12，与 token 的 `.btn 9px 20px` 不一致
- 改动：`lib/theme/app_theme.dart`（`_build`）。`buttonPadding` 改用 `DesignTokens.buttonPaddingH / buttonPaddingV`（20/9）× scale，与 `QmButton` 同源。
- 测试：`AppTheme.light()` 的 `filledButtonTheme` padding 为 `EdgeInsets(20, 9)`；scale 1.15 时为 `(23, 10.35)`。

### SR-P2-66 新学科在深色下直接用库里存的饱和色
- 改动：`lib/theme/design_tokens.dart`。`subjectColor` / `subjectInk`：亮色下存色原样用；深色下经新增 `_darkStoredMist` 雾化（向浅灰雾色 `#DCE3EC` 混 45%，色相不变、明度进雾色档，与预设三科深色雾色 `#87A9CC / #8AB5A3 / #C295A5` 同档）；预设三科不受影响；`subjectSoft` 不变。
- 与自审建议的偏差（请协调员/Meng 过目）：自审写的是“与深底 `#262B33` 按 15% 混色，复用 `subjectSoft` 深色分支的做法”。`subjectSoft` 的深色做法是底色 tint（85% 深底 + 15% 存色），用在圆点/标签字色上会暗到看不清，所以改用雾化变换；若坚持字面做法或接受现状，改 `_darkStoredMist` 一行即可。
- 测试：深色下存色 `#2E7CF6` 雾化后等于 `Color.lerp(存色, #DCE3EC, 0.45)` 且不等于存色；亮色原样；预设数学深色仍为 `#87A9CC`。

### SR-P2-67 复查提醒先写“今天已提醒”再弹框
- 改动：`lib/app.dart`（`_maybeShowRecheckReminder`）。顺序改为：条件判断 → `showDialog` → 弹框返回后（点任一按钮或按 Esc 关掉都算已展示）再写 `saveLastRecheckReminderDate`；弹框本身抛错时直接返回、不写日期，下次启动仍可再提醒；写库失败也不影响已展示的提醒。
- 未单测原因：弹框失败路径无法从公开 API 模拟；成功路径在新旧顺序下表现相同，写测试也区分不了修复，属不可单测项。以代码走读 + analyze + 既有提醒测试验证。

### SR-P2-69 `_decode` 从不 dispose `Codec`
- 改动：`lib/services/page_image_pipeline.dart` 的 `_decode` 与新增的 `canDecodeImageBytes`、`lib/services/yolo_onnx_service.dart` 的 `detectPage`，一律 `try/finally` 里 `codec.dispose()`（先取帧、再释放，帧图像不受影响）。
- 测试：同一份 PNG 连续 20 次 `cropBoxPng` + `rotateImageBytes`，结果正确、无异常，证明 dispose 没有破坏后续解码。说明：native 资源泄漏本身在 `flutter_test` 里无法直接观测，测试只能钉住“释放后解码仍正常”这一回归面。

### SR-P2-70 `rotateBoxToRotatedPage` 钳制只钳左上角
- 改动：`lib/services/page_image_pipeline.dart`。按“区间与 [0,1] 求交”算：`x' = clamp(x)`，`w' = clamp(x+w) − x'`（y/h 同理），负尺寸收到 0；与 `YoloOnnxService.clampToPage(minSize: false)` 同一语义，不补最小尺寸。
- 测试：左溢出 `x=-0.1, w=0.5 → x=0, w=0.4`、右/上/下溢出、完全在页外 → 宽高为 0、旋转后溢出（90° 后 `x=-0.2 → x=0, w=0.2`）、页内框原样不动，共 8 组断言。

### SR-P2-72 死代码 / 无用 API / 重复逻辑
- 删（全仓库零调用，grep + analyze 双重确认）：`ImportService.isAllowed`、`ScaledTokens.s()`、`YoloOnnxService.modelAsset`（`@Deprecated` 兼容垫片）。
- 标注：`PdfRenderService.renderPagePng` 加 `@visibleForTesting` + “仅测试用，生产走 `renderAllPagesToDir`”注释（生产零调用，4 处测试调用保留；为此补 `flutter/foundation.dart` import，并删掉因此变冗余的 `dart:typed_data` import）。
- 第 2 层常量：在 `intraModelAsset` 等 5 个常量上集中加“暂缓、再接入时启用”组注释；`crossClassIouThreshold` 在定义处与 `_detect` 传参处都注明“第 1 层单类时是空操作”；`_crossClassNms` 改为直接复用 `_nms`（两段原先逐字相同的实现），行为不变，既有 yolo 跨类去重测试覆盖。

### SR-P2-73 `TextScaler.linear(scale)` 完全覆盖系统字号缩放
- 决定（已定：维持现状）：decision-log 里没有独立的字号条目，最接近的是 D-11（外观组，字号设置在该组），已在 D-11 末尾补记——三档字号（1.00/1.15/1.30）覆盖系统缩放，`app.dart` 用 `TextScaler.linear(scale)` 全局乘一次，系统字号在应用内不生效，依赖系统大字号的用户需在应用内改三档；备选 `max(设置档, 系统缩放)` 未采纳。日期 2026-11-15，Batch 5 P2。
- 代码未动。

### SR-P2-74 切片解码的 `cacheWidth` 不含 `devicePixelRatio`
- 改动：`lib/widgets/widgets.dart` 两处。`QuestionSlice`：`cacheWidth = min((maxHeight × 2) × dpr, 2048)`；`CompactSliceThumb`：`cacheWidth = min(128 × dpr, 384)`。均封顶防爆内存。
- 测试：`devicePixelRatio = 3.0` 时 `QuestionSlice`（默认 maxHeight 160）的 `Image` provider 为 `ResizeImage(width: 960)`，`CompactSliceThumb` 为 `384`。

### SR-P2-75 `_ZoomDialogState.build` 里给 `_dialogScale` 赋值
- 改动：`lib/widgets/widgets.dart`。删 `_dialogScale` 字段与 build 内的赋值；`_multiply` 的回退视口尺寸改用局部变量 `qmScaleOf(context)` 现取（`_multiply` 只在按钮/滚轮回调里触发，build 之后，读当前 context 安全）。
- 测试：打开放大对话框，点 `＋` 再点 `－`，对话框仍在、无异常。

### SR-P2-76 多处 UI 线程同步文件 IO
- 决定（维持现状，按自审修的方向）：不改异步。P0.5 已实测同步读一张 1653×2200 PNG 约 0.22–3.2ms，打开慢的主因是 YOLO 推理约 3–6 秒；后续优化打开体感时优先把推理放后台、先显页图，而不是只改读图方式。
- 改动：只在 `lib/services/import_service.dart` 的 `pageImageRelativeForTask` 上加注释写明上述依据；`yolo_onnx_service.dart` 原已有同款注释，未动；`lib/widgets/widgets.dart` 里的三处 `existsSync`（`QuestionSlice` / `CompactSliceThumb`）未加注释——该文件是共享文件，`QuestionSlice` 区域属另一工人，决定记在这里，不越界改动。
- 无测试（无行为变化）。

### SR-P2-77 三组单测首次并行跑时 `pdf_render_service_test.dart` 出现 10 项失败
- 改动（只动测试侧，未动产品代码）：`flutter_test` 的 `group()` 没有 `timeout` 参数（只支持 `skip`/`retry`，查 SDK 源码确认；第一次按 group 加超时导致 analyze 报错，已改回），改为给每个 `test` 加 `timeout: const Timeout(Duration(minutes: 5))`——`test/pdf_render_service_test.dart` 13 个测试全加、`test/yolo_onnx_service_test.dart` 真实模型冒烟组 4 个测试加，并附头注说明并行抖动成因（1.5 CPU 下 YOLO 推理与 PDF 渲染抢 CPU，复跑全过，非回归）。
- 验证：两文件单文件串行跑全过（PDF 13/13、YOLO 25/25）。

## 改动文件

| 文件 | 改动 |
|---|---|
| `lib/services/import_service.dart` | SR-P2-59/60/61/62/72（删 `isAllowed`）/76（注释） |
| `lib/services/page_image_pipeline.dart` | SR-P2-69（`_decode` dispose）、SR-P2-61（新增 `canDecodeImageBytes`）、SR-P2-70（钳制） |
| `lib/services/yolo_onnx_service.dart` | SR-P2-69（codec dispose）、SR-P2-72（删 `modelAsset`、第 2 层注释、`_crossClassNms` 复用 `_nms`） |
| `lib/services/pdf_render_service.dart` | SR-P2-72（`renderPagePng` 标仅测试用；import 整理） |
| `lib/widgets/uikit.dart` | SR-P2-63（`QmSegmented` 去外层 Opacity）、SR-P2-64（`_QmPressable.childHandlesTap` + `QmChip` 双区） |
| `lib/widgets/widgets.dart` | SR-P2-74（两处 `cacheWidth` × dpr）、SR-P2-75（删 `_dialogScale`） |
| `lib/theme/app_theme.dart` | SR-P2-65（按钮内边距用 token） |
| `lib/theme/design_tokens.dart` | SR-P2-66（存色深色雾化）、SR-P2-72（删 `ScaledTokens.s()`） |
| `lib/app.dart` | SR-P2-67（提醒先弹框后写库） |
| `docs/decision-log.md` | SR-P2-73（D-11 补记三档字号覆盖系统缩放） |
| `test/b5_p2_services_test.dart` | 新增，14 个测试 |
| `test/pdf_render_service_test.dart` | SR-P2-77（13 个测试加 5 分钟超时） |
| `test/yolo_onnx_service_test.dart` | SR-P2-77（冒烟组 4 个测试加 5 分钟超时） |

未动：`lib/main.dart`、`lib/widgets/app_shell.dart`（没有对应项；`app_shell` 无同步 IO）、`lib/services/zip_archive.dart`（SR-P2-68 不属本组）、`lib/data/*`、各页面文件、`docs/*` 其余部分。未 commit、未推代码。

## 新增测试与通过数

新文件 `test/b5_p2_services_test.dart`：14 个测试，14/14 通过（内存库 + 临时数据目录，不碰演示库；演示库 md5 仍为 `8f7f9c64…`）。

既有针对性测试（全部单文件串行、`--concurrency=1`，通过数）：

| 文件 | 结果 |
|---|---|
| `test/uikit_test.dart` | 30/30 |
| `test/theme_smoke_test.dart` | 8/8 |
| `test/widgets_forward_test.dart` | 2/2 |
| `test/p05_image_pipeline_test.dart` | 11 通过、2 跳过（P05 原有跳过） |
| `test/import_service_p1_fixes_test.dart` | 8/8 |
| `test/import_service_pdf_fallback_test.dart` | 2/2 |
| `test/s8b4_reminder_test.dart` | 11/11 |
| `test/yolo_onnx_service_test.dart` | 25/25（`LD_LIBRARY_PATH=onnxruntime-1.4.1/linux`） |
| `test/pdf_render_service_test.dart` | 13/13 |
| `test/pdf_collect_page_test.dart` | 1/1 |
| 合计 | 111 通过、2 跳过 |

`flutter analyze`：0 问题（中途曾出现 2 个 warning，均为新测试文件里 `?.` 用于非空接收者，已修掉再验）。

## 过程中遇到的环境问题（已解决，记下来供协调员参考）

1. **工具链丢失**：中途 clang 消失（VM 替换后丢失），`pdfium_dart` hook 报 `No compiler configured`。`docs/ui-replication/restore-linux-toolchain.sh` 原脚本两次失败——内嵌 urllib 在拉 `noble/universe` 索引（约 19MB）时 14MB 处断流 `IncompleteRead`。用 `/tmp/restore-toolchain-patched.sh`（仓库脚本的副本，把下载换成带重试的 curl）重跑后 clang 恢复；PDF 渲染测试 13/13 通过即证明编译器可用。`/tmp` 下的补丁副本未进仓库，原脚本未改。
2. **并行跑测试卡死**：七文件同跑 `flutter test` 在前端编译器卡 41 分钟（CPU 仅 2 秒），由协调员按精确 PID 停掉。之后全部改为单文件串行 + `--concurrency=1`，再未卡住。
3. **testWidgets 里异步文件 IO 会挂起**：`testWidgets` 体内的 `await File.writeAsBytes` / `PictureRecorder.toImage()` 在 FakeAsync 环境下无 pump 时永不完成（探针二分证实：无文件 IO 的对照通过，有异步 IO 的全挂 60 秒超时）。新测试的 widget 部分改用同步 IO（`createSync` / `writeAsBytesSync`）和硬编码 1×1 PNG base64 常量解决；`pumpAndSettle` 也改用 `pump()`。后续工人写 widget 测试时注意这一点。

## 遗留问题与需转交其他工人的改动说明

1. **SR-P2-60 的同类问题在收集页（未修，需协调员定）**：`lib/modules/collect/collect_page.dart:322`（`'task-<ms>-<fileName.hashCode>'`）与 `:549`（`'task-$ts-$p-$i'`）用的也是“毫秒时间戳 + 序号”式 id，有同样的同毫秒撞 id 风险。自审条目只点名 `import_service.dart:184`，且 `collect_page.dart` 不属本组文件范围，故未动。请协调员确认是否让页面工人同款加随机段。
2. **SR-P2-66 的做法与自审字面建议有偏差**（见上文）：用雾化变换而非“深底混 15% 存色”。请 Meng/协调员过目；若要改回字面做法或接受现状，只改 `_darkStoredMist` 一行。
3. **SR-P2-67 无可区分的单测**（见上文）；SR-P2-69 的 native 泄漏本身无法在 `flutter_test` 里直接观测，测试只钉住“释放后解码仍正常”。
4. **SR-P2-76 的 `widgets.dart` 三处 `existsSync` 未加注释**（共享文件，`QuestionSlice` 区域属另一工人）；决定记在本报告。
5. **`lib/widgets/widgets.dart` 是共享文件**：本组只改了 4 处精确位置（两处 `cacheWidth`、`_dialogScale` 字段与赋值、`_multiply` 局部变量）。另一工人同期也在改该文件，行号中途已变，我每次编辑前都重读了文件；阶段统一验证时请留意该文件的合并状态。
6. **`docs/decision-log.md` 只动了 D-11 一处补记**；文档工人的其他条目未碰。
