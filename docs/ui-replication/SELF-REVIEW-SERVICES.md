# 最终自审 · 服务层 / 模型 / 主题 / 外壳

- 范围：`lib/services/`（import / page_image_pipeline / pdf_render / recheck_reminder / yolo_onnx / zip_archive）、`lib/models/models.dart`、`lib/theme/`（design_tokens / app_theme）、`lib/widgets/app_shell.dart`、`lib/widgets/uikit.dart`、`lib/widgets/widgets.dart`（通用组件部分）、`lib/app.dart`、`lib/main.dart`；另读 `YOLO-INTEGRATION-REPORT.md`、`P0B2-PDF-REPORT.md`、`P0B2-P05-SPIKE-REPORT.md` 了解设计意图。
- 方式：逐文件通读 + `flutter analyze` + 针对性单测（`yolo_onnx_service_test.dart`、`p05_image_pipeline_test.dart`、`pdf_render_service_test.dart`）。只审、不改；未动任何代码，未 commit/push。
- 结论：**共 24 项：P0 × 1、P1 × 4、P2 × 19。**
- 验证：`flutter analyze` 0 问题；三组针对性单测复跑 50/50 通过（首次三组并行跑时 `pdf_render_service_test.dart` 曾出现 10 项失败，见 P2-19，并行争用抖动，非代码回归）；演示库 md5 跑前后均为 `8f7f9c64405dc6e484ac2bf8e5e1a807`（v1、9 题），未动。演示库备份在 `~/workspace/demo-db-backup/quiz-master2.db`。

---

## P0

### P0-1 · 38MB YOLO 模型文件没有任何 `.gitignore` 保护，一次 `git add .` 即入库

- 位置：`assets/models/question/yolo11s-question-v1.onnx`；`.gitignore`（全文 grep，无 `models`/`onnx` 规则）；`pubspec.yaml:33,37`
- 现象：`git status` 显示 `?? assets/models/question/`（未入库、未忽略）；`git check-ignore` 确认 NOT IGNORED；`pubspec.yaml` 用 `- assets/models/` + `- assets/models/question/` 声明，模型打进包是正确的，但仓库层面无任何防线。
- 后果：与既定决定“模型文件 38MB 不进仓库、Meng 自己放 `assets/models/question/`”直接冲突；一次习惯性的 `git add .` 就会把 38MB 二进制写进历史，之后清理历史的成本远高于现在加一行忽略规则。这也是 Batch 3 汇总遗留的第 (1) 点，属实。
- 修的方向：在 `.gitignore` 加 `assets/models/question/*.onnx`（或 `assets/models/**/*.onnx`，保留 `assets/models/README.md` 入库）；并核对 `git ls-files assets/` 确认只有 README 在库内。

---

## P1

### P1-1 · 图片 20MB 上限只提示不执行；超限横幅文案与 PDF 硬失败自相矛盾

- 位置：`lib/services/import_service.dart:145-157`（`oversizeHint`）、`enqueue` 内 PDF 50MB 硬判（约 :209-224）、图片分支无任何尺寸硬判；`lib/modules/collect/collect_page.dart:766-771`（横幅）
- 现象：
  - `maxImageBytes`（20MB）在全仓库只被 `oversizeHint` 用到一次；`enqueue` 里 PDF 超 50MB 会直接进 `failed` 任务，图片超 20MB 没有任何拦截，照常复制、归一化、进 `needBox`。“图片限 20MB”这条决定实际未执行。
  - 收集页横幅标题写的是“文件超过大小上限，只是提示，不直接判失败”，文案是“仍可继续导入”。对 PDF 这是假话：用户点“仍然再导一份”后 `enqueue` 仍会把 >50MB 的 PDF 判失败，横幅承诺落空；对图片则是另一方向的假话：根本没有上限可言。
- 后果：超大图片悄悄入库（检测更慢、多占 2GB 预算）；用户按横幅指引操作却得到失败任务，信任受损。
- 修的方向：二选一并统一文案——（a）`enqueue` 对图片也硬判 20MB，横幅按 PDF/图片区分说法；或（b）PDF 也改回只提示（与 §6 第 3 条“限 50MB”冲突，不建议）。建议 (a)。

### P1-2 · `CompactSliceThumb` 的 `Image.file` 没有 `errorBuilder`，损坏切片无失败占位（第三批汇总遗留点，属实）

- 位置：`lib/widgets/widgets.dart:609`（`Image.file(sliceFile, fit: BoxFit.cover, cacheWidth: 128)`，无 `errorBuilder`）；对照 `lib/widgets/widgets.dart:393-400`（`QuestionSlice` 的同一位置有 `errorBuilder`，走 `_missingImagePlaceholder`）
- 现象：紧凑列表里切片文件存在但内容损坏/解码失败时，`Image.file` 不显示“加载失败/图片缺失”占位，只剩空白框或框架错误日志；`failed`/`missingRealImage` 两条占位分支都走不到（文件存在，`existsSync` 为真）。
- 后果：错题本紧凑视图出现空白缩略图，用户无法区分“没图”和“图坏了”，与大卡片行为不一致。
- 修的方向：给 `:609` 的 `Image.file` 补 `errorBuilder`，复用 `:563-600` 失败分支的同一占位（学科图标 + “加载失败”）。

### P1-3 · YOLO 模型首次加载失败后永久锁死，运行中补放模型文件也无法恢复

- 位置：`lib/services/yolo_onnx_service.dart:119,173-174`（`static bool _loadAttempted`；`if (_loadAttempted) return _loadOk;` 后 `_loadAttempted = true`）；唯一重置点是 `@visibleForTesting resetLoadStateForTest`（:106）
- 现象：`_ensureLoaded` 失败一次后 `_loadAttempted` 恒为真，之后每次 `detectPage` 都直接返回“自动检测不可用，请手动框选”，不再尝试加载。Meng 在应用运行中把模型文件放进 `assets/models/question/`（或首次是权限/路径问题）后，必须重启应用才生效。
- 后果：与“模型文件 Meng 自己放”的工作流直接摩擦；用户看到的是一直不可用的检测，没有任何“重试”入口。
- 修的方向：加载失败时不锁死 `_loadAttempted`（或失败后按调用次数/时间间隔重试，如每 N 次检测重试一次）；至少在 `detectPage` 的 fallback 路径上允许下一次调用重走 `_ensureLoaded`。

### P1-4 · `ImportService.enqueue` 的重复判断是空分支；同批两次选同一文件会静默建两个任务

- 位置：`lib/services/import_service.dart:185,195-200`（`final duplicate = existing.any(...)`，随后 `if (duplicate) { /* 只有注释 */ }`）；`lib/modules/collect/collect_page.dart:180-194`（重复判断只查已入库的 `_tasks`）
- 现象：
  - 服务层算出了 `duplicate` 却没有任何行为：不拦、不标记、不返回，任务照常创建。重复提示完全依赖收集页自己的 `_tasks` 快照，`enqueue` 被其他调用方复用时无任何去重。
  - 同批内重复也查不到：收集页只拿本次选中的路径与已入库任务比对，同一文件在一次多选里出现两次时，两次都不在 `_tasks` 里，横幅不弹，直接建两个重复任务；服务层的 `existing` 快照同样不含本批刚建的任务。
- 后果：重复任务、重复切片、重复占 2GB 预算；用户要手动删。
- 修的方向：把去重收进 `enqueue`：快照改为边建边更新（含本批已建任务），重复文件直接跳过或返回带 `duplicate: true` 的结果给调用方弹“已经导入过”；`duplicate` 变量要么生效要么删除。

---

## P2

### P2-1 · `_importPdf` 的存储估算把原文件算了两次，接近 2GB 上限时会误拒合法 PDF

- 位置：`lib/services/import_service.dart:356-363`
- 现象：`used = storageUsageBytes()` 时原文件已复制进 `imports/<task>/original.pdf`（已计入 `used`），估算却又加了一次 `fileSize`：`used + fileSize + total × 2MB > 2GB`。
- 后果：只在总占用距 2GB 不到一个 PDF 大小时触发，误拒本可导入的 PDF，提示却是“空间不足”，用户删文件也未必能对上账。
- 修的方向：估算改为 `used + total × estimatedBytesPerRenderedPage`（原文件已在 `used` 里）。

### P2-2 · 任务 id 是“毫秒时间戳 + 批内序号”，同一毫秒内两次导入可能撞 id

- 位置：`lib/services/import_service.dart:184`（`'task-${DateTime.now().millisecondsSinceEpoch}-$i'`）
- 现象：两次 `enqueue` 在同一毫秒启动且序号相同（都是 `$i = 0`）时生成同一 id，后一次 `upsertCollectTask` 会覆盖前一次的任务行。
- 后果：概率低但非零（快速连续导入/自动化调用时），丢任务且无报错。
- 修的方向：id 后缀加随机段（如 6 位随机数）或改用递增计数器 + 随机段。

### P2-3 · 图片解码失败时静默按原图继续进 `needBox`，损坏图片不进 `failed`

- 位置：`lib/services/import_service.dart:300-307`（EXIF 分支的 `catch (e)`：注释“读不到 / 解码失败：原图已拷进库，仍可继续”）
- 现象：改后缀的非图片文件（如 `.txt` 改 `.jpg`）能通过扩展名检查，解码失败后仍建成 `needBox` 任务；修框编辑器打开时才暴露解码失败。
- 后果：失败发现得晚，任务状态误导（“待框选”实际是“打不开”）。
- 修的方向：解码失败且文件确实不是图片时进 `failed` 并提示“这张图片打不开”；仅当失败原因不明确时才保留现有降级。

### P2-4 · 复制进度每次百分比变化都写一次库，一个文件最多约 70 次写库

- 位置：`lib/services/import_service.dart` 复制循环内 `onProgress` + `_updateProgress`（0→70% 每 1% 一次）；`_updateProgress` 本身只写 progress、不 bump（节流注释属实，但写库次数未节流）
- 现象：与注释“§4.3 节流”的意图不完全一致——状态变化确实节流了，进度写库没有。
- 后果：机械硬盘/慢盘上导入大文件时多余写放大；一般 SSD 上无感。
- 修的方向：进度写库节流到每 5% 或变化 ≥5 个百分点时写一次，UI 回调保持逐次。

### P2-5 · `QmSegmented` 禁用态是双重 0.45 透明度（实际约 0.20），目前未触发

- 位置：`lib/widgets/uikit.dart:1073-1074`（`if (!enabled) return Opacity(opacity: 0.45, child: body)`）+ `:248`（`_QmPressable` 在 `onTap == null` 时又包一层 `Opacity(0.45)`）
- 现象：`onChanged == null` 时每段先被 `_QmPressable` 置 0.45，外层再乘 0.45，整体约 0.20，远低于 HTML `.btn:disabled{opacity:.45}` 的规定。
- 后果：潜在；核查两个调用点（`report_page.dart:332`、settings `_segmented`）目前都传非空 `onChanged`，线上无禁用态分段控件。
- 修的方向：去掉 `QmSegmented` 外层的 `Opacity`，只留 `_QmPressable` 的一层；或反过来让 `_QmPressable` 接受“已由父级处理透明度”的标志。

### P2-6 · `QmChip` 可删除 + 可点双区时，内外两层 Tap 识别器竞争同一手势

- 位置：`lib/widgets/uikit.dart:535,619-640`（`bothZones` 时外层 `_QmPressable(onTap: onTap ?? onDelete)` 包着内层两个 `GestureDetector(onTap: onTap / onDelete)`）
- 现象：点标签、点 `×` 都同时经过两层 Tap 识别器，最终谁赢依赖手势竞技场的裁决顺序；无单测覆盖该分支。
- 后果：目前未观测到双触发，但结构脆弱，后续改动容易把它变成“点一次删两次/切换两次”。
- 修的方向：只留一层手势——外层 `_QmPressable` 的 `onTap` 传 null（只做视觉与焦点），点按全由内层两个 `GestureDetector` 承担；或补一个双区点按单测钉死行为。

### P2-7 · `AppTheme` 的主题按钮垂直内边距是 12，与 token 的 `.btn 9px 20px` 不一致

- 位置：`lib/theme/app_theme.dart:121`（`vertical: 12 * scale`）；对照 `lib/theme/design_tokens.dart`（`buttonPaddingV = 9`，注释“.btn 9px 20px”）与 `QmButton`（用 9）
- 现象：走 `ThemeData` 的 `FilledButton/OutlinedButton/TextButton`（如对话框按钮）比 `QmButton` 高约 6px，两套按钮高度不统一。
- 修的方向：`_build` 里的 `buttonPadding` 改用 `DesignTokens.buttonPaddingV/buttonPaddingH`，与 `QmButton` 同源。

### P2-8 · 新学科在深色下直接用库里存的饱和色，与“深色只用冷雾色”不一致

- 位置：`lib/theme/design_tokens.dart`（`subjectColor`/`subjectInk` 的 `stored != null` 分支：预设三科之外直接返回存色，不分亮深）
- 现象：新学科在深色模式下圆点/标签用的是亮色轮换色（如饱和蓝/绿），与预设三科深色下的雾色（`#87A9CC` 等）不是同一档视觉。
- 后果：新学科一多，深色导航/标签里出现刺眼的饱和色点；S8A2 只定了“新学科用存色”，没定深色怎么处理。
- 修的方向：深色下对存色做处理（如与深底 `#262B33` 按 15% 混色，复用 `subjectSoft` 深色分支的做法）或由 Meng 明确接受现状。

### P2-9 · 复查提醒先写“今天已提醒”再弹框，弹框失败则当天提醒永久丢失

- 位置：`lib/app.dart:171`（`saveLastRecheckReminderDate` 在 `showDialog` 之前）；`lib/services/recheck_reminder.dart` 四条件本身无误
- 现象：写库与弹框之间若上下文失效、弹框抛错，当天已被标记为提醒过，`_reminderChecked` 又保证一轮应用只判断一次，提醒不再出现。
- 后果：小概率丢一次提醒；注释里已承认“弹框本身失败也不再重复弹”，是已知取舍但顺序可以更稳。
- 修的方向：`showDialog` 返回后再写日期；或写库失败/弹框失败时不写日期。

### P2-10 · `readZip` 不解析中央目录，不支持带数据描述符的 zip；只含目录条目的空 zip 静默返回空列表

- 位置：`lib/services/zip_archive.dart`（`readZip` 按 local header 顺序读，遇中央目录/结束标记即停；`entries.isEmpty && off == 0` 才抛错）
- 现象：
  - 流式写入的 zip（local header 里 flag bit 3 置位、尺寸在数据后的描述符里）会被误读（尺寸取 0），随后以“结构损坏”抛错，文案没说明是这种 zip 不支持。
  - 只含目录条目的 zip（`off > 0` 但无文件条目）返回 `[]` 而不报错。
  - 单个条目的解压在累计 `total` 检查之前完成，超大单条目会先占满内存再触发 4GB 上限。
- 后果：自家备份不受影响（写出方从不置 bit 3）；用户用外部工具重打包的 zip 可能被拒；两个恢复入口（`db_backup.dart`）都会因缺 `backup.json` 而拒掉空包，所以无静默恢复风险。
- 修的方向：按中央目录校验条目数与偏移；解压前先用 local header 的 `rawSize` 做上限预判；空条目列表直接抛错。

### P2-11 · `_decode` 从不 dispose `Codec`，每次解码漏一份 native 资源

- 位置：`lib/services/page_image_pipeline.dart:202`（`instantiateImageCodec` 后只取 `frame.image`，codec 未 dispose）；同款调用在 `lib/services/yolo_onnx_service.dart:145`
- 现象：`Codec.dispose()` 未调用；`page_image_pipeline` 的 `cropBoxPng`/`rotateImageBytes`、`detectPage` 每页都会走这条路。
- 后果：单次泄漏小，高频修框/批量检测时 native 资源累积；目前未观测到可感知的内存问题。
- 修的方向：`try/finally` 里 `codec.dispose()`（需先确认当前 Flutter 3.47 的 `Codec` 有公开 `dispose`）。

### P2-12 · `rotateBoxToRotatedPage` 钳制时只钳左上角，不缩宽高，页外伸入的框会被拉宽

- 位置：`lib/services/page_image_pipeline.dart:66`（`w: nw.clamp(0.0, 1.0 - nx.clamp(0.0, 1.0))`；`nx` 被钳到 0 但 `nw` 未减去被裁掉的部分）
- 现象：如 `x = -0.1, w = 0.5` 的框，钳制后变成 `x = 0, w = 0.5`（应为 0.4），框整体右移且变宽；YOLO 输出本身都在页内，触发需手画/外部输入的越界框。
- 后果：低概率的框错位，仅影响越界输入。
- 修的方向：先钳 `x/y`，再按 `w = min(w, 1 - x)` 且从被裁一侧扣除溢出量（或复用 `clampToPage` 的同一钳制逻辑）。

### P2-13 · YOLO 报告过期：仍写“模型缺失时回退占位框”，与现行代码不一致

- 位置：`docs/ui-replication/YOLO-INTEGRATION-REPORT.md` §2（“模型缺失、加载失败或图片文件不存在时回退占位（一页一个整题框）”）、§8（“Meng 需自己推这两个文件”）
- 现象：现行 `yolo_onnx_service.dart` 的 `DetectionResult` 注释与实现都是“模型失败不回占位框，返回空框 + `usedFallback: true`”；第 2 层模型已移出仓库且暂缓，只需第 1 层。
- 后果：文档与代码口径分裂，后续接手者会按报告去找并不存在的占位逻辑。
- 修的方向：更新报告 §2/§8，与 D-23“只接第 1 层、失败不回占位”对齐；§6 的 388/388 测试数也已过期（现为 628），顺手更新。

### P2-14 · 死代码 / 无用 API / 重复逻辑（第 2 层残留与“暂缓”一致，但应标注）

- 位置：
  - `lib/services/import_service.dart:139` `ImportService.isAllowed`：全仓库零调用（选文件走 `FilePicker` 的 `allowedExtensions`）。
  - `lib/services/pdf_render_service.dart:189` `PdfRenderService.renderPagePng`：生产代码零调用，只有测试用。
  - `lib/theme/design_tokens.dart` `ScaledTokens.s()`：零调用。
  - `lib/services/yolo_onnx_service.dart:59` `@Deprecated modelAsset` getter：零调用的兼容垫片。
  - `lib/services/yolo_onnx_service.dart:70-93` 第 2 层占位常量（`intraModelAsset`/`intraInputSize`/`intraConfThreshold`/`intraClassTypes`/`crossClassIouThreshold`）：与“第 2 层暂缓、`intraEnabled = false`”一致，是有意的再接入记录，但其中 `crossClassIouThreshold` 还在第 1 层调用里传参（单类时跨类去重是空操作），容易误读为生效参数。
  - `lib/services/yolo_onnx_service.dart` `_nms` 与 `_crossClassNms`：两段逐字相同的实现（同是按置信度排序后 IoU 压制）。
- 修的方向：删 `isAllowed`/`ScaledTokens.s()`/`modelAsset`；`renderPagePng` 标注“仅测试用”或移到测试 helper；第 2 层常量集中加一句“暂缓、再接入时启用”的注释（已有部分注释，补齐 `crossClassIouThreshold` 在第 1 层是空操作这一点）；`_crossClassNms` 复用 `_nms` 的实现。

### P2-15 · `TextScaler.linear(scale)` 完全覆盖系统字号缩放，无障碍大字号被三档设置取代

- 位置：`lib/app.dart`（`builder` 里 `media.copyWith(textScaler: TextScaler.linear(scale))`）
- 现象：三档（1.00/1.15/1.30）是唯一缩放来源，系统级字号设置被丢弃；`qmScaleOf` 也只读这个值。
- 后果：按 D4 设计是既定行为（字号只乘一次），但依赖系统大字号的用户会发现应用内字号不受系统控制。
- 修的方向：由 Meng 定夺：维持现状（明确写进决定），或取 `max(设置档, 系统缩放)`。

### P2-16 · 切片解码的 `cacheWidth` 不含 `devicePixelRatio`，高分屏切片偏糊

- 位置：`lib/widgets/widgets.dart:396`（`cacheWidth: (maxHeight * 2).ceil()`，`maxHeight` 是逻辑像素）；`:609`（`cacheWidth: 128` 写死）
- 现象：2x/3x 屏上解码分辨率只有逻辑尺寸的 2 倍，低于显示所需像素；注释说“按显示尺寸解码，不解全分辨率大图”是对的，但“显示尺寸”应乘 `devicePixelRatio`。
- 后果：高分屏上切片文字轻微发虚；低分屏无影响。
- 修的方向：`cacheWidth` 乘 `MediaQuery.devicePixelRatioOf(context)`（并设上限防爆内存）。

### P2-17 · `_ZoomDialogState.build` 里给 `_dialogScale` 赋值（build 内改状态）

- 位置：`lib/widgets/widgets.dart:940`（`_dialogScale = scale;` 在 `build` 内）；`:853` 声明
- 现象：`_dialogScale` 只在 `_multiply` 的 fallback 视口尺寸里用到，而 `_multiply` 只在按钮/滚轮回调里触发（build 之后），目前工作正常。
- 后果：build 内写字段是坏味道，后续若有人在 build 流程里读它会拿到上一帧的值。
- 修的方向：移到 `didChangeDependencies` 或直接用局部变量传参。

### P2-18 · 多处 UI 线程同步文件 IO（已知、已实测很小）

- 位置：`lib/services/yolo_onnx_service.dart:144-146`（`existsSync`/`readAsBytesSync`）、`lib/services/import_service.dart:74`（`pageImageRelativeForTask` 内 `existsSync`）、`lib/widgets/widgets.dart`（`QuestionSlice`/`CompactSliceThumb` 的 build 内 `existsSync`）
- 现象：P0.5 报告已实测同步读 1653×2200 PNG 约 0.22–3.2ms，解码 10–27ms；打开慢的主因是 YOLO 推理约 3–6 秒，不是同步读。
- 后果：目前无可感知卡顿；P05 报告原话“生产用异步读或 isolate 仍值得做”。
- 修的方向：低优先级；后续优化打开体感时优先把推理放后台、先显页图，而不是只改读图方式。

### P2-19 · 三组单测首次并行跑时 `pdf_render_service_test.dart` 出现 10 项失败，复跑全过（测试侧观察，非产品 bug）

- 位置：`test/pdf_render_service_test.dart`（与 YOLO/P05 两组并行时）
- 现象：首次三组并行：PDF 组 10 项失败（含 21 页上限、3 页导入、加密 PDF 导入等）；随后 PDF 组单独跑 13/13 通过，三组并行复跑 50/50 通过。
- 后果：与 P0B2 报告里“固定等待在全量并行时会因 CPU 争用超时”同源——1.5 CPU 下 YOLO 推理（每页 3–6 秒）与 PDF 渲染抢 CPU，超时类失败是抖动，不是回归。
- 修的方向：不动产品代码；给耗时测试留超时余量，或把真实推理测试与 PDF 测试分开跑。

---

## 审过且干净的地方

- **YOLO 只接第 1 层**：`intraEnabled = false`（`yolo_onnx_service.dart:66`），`_detectIntra` 恒返回空；`questionConfThreshold = 0.45`、`nmsIouThreshold = 0.5` 与决定一致；`decodeYoloOutput` 逐类 NMS + 跨类去重逻辑正确；letterbox（灰边 114、等比缩放）与 `_letterboxToSource`/`_toPageBox` 的坐标换算正确（P05 报告像素差 0.0 佐证）；`clampToPage(minSize: false)` 保留检测框实测尺寸；阅读顺序编号 `box-q1…`；失败不回占位框（`DetectionResult.usedFallback`）。`groupInners` 仍被 `box_editor.dart:369` 复用（手动内框归属），不是死代码。
- **EXIF**：手写 APP1 解析只读 tag `0x0112`，截断/非 JPEG 返回 null 不抛错；`normalizeExifImageBytes` 利用 dart:ui 解码已转正的特性只做重编码，不二次旋转；镜像方向 2/4/5/7 在 `import_service.dart` 显式失败并提示，不静默错向。
- **PDF**：50MB 复制前判、20 页 `pageCount` 后判、0 页判损坏、加密/损坏进 `failed` + 删目录（`_failAndClean`）；整本渲染逐页写盘、逐页释放；页图长边 2500；`renderAllPagesToDir` 命名与 `renderedPageRelative` 一致（`page-001.png`…）。
- **旋转烘焙**：`rotateBoxToRotatedPage`/`cropRotatedSlice` 三角度像素差 0.0（P05 报告 §2/§5）；`rotateImageBytes` 明确要求输入无 EXIF，注释写清禁令。
- **切片裁剪**：`cropBoxPng` 像素四舍五入后钳制进图内，全在图外时抛 `ArgumentError` 而不是静默出空图。
- **zip 备份/恢复**：写出 deflate + CRC32、`buildZip` 校验条目名；读入校验 CRC 与尺寸、拒绝 `..`/绝对路径/盘符、拒绝加密 zip、4GB 解压上限；备份表含 `collect_tasks`/`review_state`/`review_history`/`recent_tasks`（`database.dart:113-127` 全部 14 张表）；恢复走 staging + 原文件备份回滚（`db_backup.dart`），只打包库里引用到的文件。
- **复查提醒**：四条件（开关开、有到期的错因、已到当日提醒时间、今天没提醒过）在 `recheck_reminder.dart` 的 `shouldShowRecheckReminder` 里实现正确，含整点那一刻；写坏的 `notifyTime` 回落 20:00；`recheckDueCauseCount` 按错因计数，与弹框文案“有 N 个错因”口径一致；`CauseRecord.isRecheckDue` 按日期比（已解决且复查日 ≤ 今天）。
- **主题/字体**：浅色亮蓝白、深色冷灰两套 token；`FontScale` 1.00/1.15/1.30 与 `AppSettings.fontScale` 同源；字号只在 `app.dart` 的 `MediaQuery TextScaler` 乘一次，`TextTheme` 取基准值；`AppTheme` 的兼容常量与 token 逐项对得上（抽查 accent/muted/深色纸面均一致）；不打包字体，只声明 `Segoe UI` + 回退栈。
- **启动页**：`resolveStartupRoute` 白名单 9 顶级路由，`/question/:id` 不在其中；`startupPage` 非法/为空回落 `/home`；自愈写回逻辑正确；设置读失败时用默认设置继续跑，不崩启动。
- **左导航**：角标口径与注释一致（收集 = 待框选 + 修框中 + 待整理；整理 = 待整理）；学科速览 `.take(5)` 上限 5 科；新学科经 `badgeVersion` 监听同步到导航（`app.dart:_refreshBadges` 读 `repo.subjects()`），圆点色走 `subjectColor` 的 stored 回退。
- **导入其他项**：只接受 PDF/JPG/PNG（`allowedExtensions` + FilePicker）；每次导入选学科、默认“请选择学科”在收集页侧实现（无默认学科）；2GB 空间上限在复制前与 PDF 渲染前各估算一次；`oversizeHint` 的 PDF/图片分档（50/20MB）数值正确（问题只在执行层，见 P1-1）。
- **模型层**：`Question.copyWith` 的 clear 标志完整；`ReviewQueueItem` 对象化后自定义错因含 `,`/`|` 不再切错；`hasBannedNameSeparator` 只禁 `,`/`，`/`|`，与 §6 第 4 条一致；`Subject.byId` 未知 id 回退数学是已知取舍（调用方传 `subject` 对象时已规避）。
- **通用组件**：`QmFoldSection` 三形态（group/form/detail）与调用方的互斥约定一致；`QmChip` 选中态学科色/深色字色正确；`QmEmptyState` 与 `CompanionWidget` 形态一致；zoom overlay 初始矩阵按视口尺寸算（`_centerInitial` 的绕视口中心缩放，S8A1 报告结论已落实）；`QuestionSlice` 有 `errorBuilder`（与 P1-2 的 `CompactSliceThumb` 形成对照）。
- **YOLO 报告与代码一致的部分**：阈值、letterbox、编号、耗时量级（Linux 3.5–6.8 秒/页，复测稳态 5.4–6.8 秒）均与报告相符；不一致的只有 P2-13 列出的两处过期表述。
