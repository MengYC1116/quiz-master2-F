# 第三次自审 · 服务层 / 主题 / 组件（SERVICES）

- 日期：2026-11-15
- 范围：只审第六批改动（`docs/ui-replication/B6-P2-SERVICES.md`、`B6-P2-GAPS.md`、`B6-SUMMARY.md` 所列 D-services 与 SR2-73 补漏部分），不审全量代码；只审、不改代码。
- 工作树：`~/workspace/quiz-master2-UI`，分支 `ui-replication`。注意：本地 head 仍是 `bca8586`，简报所说的 `38cbc4b` 本地不存在，第六批改动以未提交的工作树状态审（以 `/tmp/b6-files.txt` 的 01:30–04:00 UTC 窗口 + 三份 B6 报告圈定）。
- 审阅文件：`lib/services/yolo_onnx_service.dart`、`lib/widgets/uikit.dart`、`lib/widgets/widgets.dart`、`lib/modules/subjects/subjects_page.dart`；测试 `test/yolo_onnx_service_test.dart`、`test/b5_p2_services_test.dart`、`test/s8_chip_label_test.dart`、`test/b5_p1_1_subject_counts_test.dart`。
- 验证手段：除静态核对与独立复算外，写了 3 个临时探针测试（跑完已删）：金角循环探针（真实 Dart `HSVColor` 复算 13–30 科）、gate 毒化探针、4 路并发真模型探针；另实跑 `test/yolo_onnx_service_test.dart` 单文件（真模型 + 原生库，27/27 通过）。

## 结论先行

- 共 **5 项**：P0 0 项，P1 0 项，**P2 5 项**。其中 4 项是第六批自己引入的，1 项（SERVICES-5）是非第六批引入的 B2 遗留，但属于本次任务点名要核的“是否还有别的入口直接返回存色”，故编号列出并标明来源。
- 没有 P0/P1：YOLO 串行化经真模型实测有效（2 路用例 + 4 路探针均未崩溃），加载共享、测试门禁、雾化色值、第 13 科金角、芯片尺寸、minSize 路径、2GB/dpr/回调/ZIP 四组测试均已证实无问题。

---

## SERVICES-1（P2）— SR2-31：金角 25° 保护在第 15 科起静默失效，36 步兜底返回近乎撞色的颜色

- 位置：`lib/modules/subjects/subjects_page.dart:322-341`（`_addSubject` 的 `orElse` 金角循环）；`B6-P2-SERVICES.md`“第 14、15…科生成色同样受 25° 阈值保护”的说法不成立。
- 现象：第 13 科（284°、`0xFFB34CD9`，最小色相距 31.8°）与第 14 科（135.5°，最小色相距 31.8°）都合规；但从第 15 科起，`guard < 36` 的 37° 步进在 36 步内找不到任何与全部已用色拉开 ≥25° 的色相，循环退出后**直接返回仍违规的颜色**，没有任何提示或降级。色相距一路跌到 0.7°（第 23 科 37.0°，与琥珀 `0xFFF59E0B` 的 37.7° 只差 0.7°，肉眼无法区分）。
- 证据：临时探针（真实 Dart `HSVColor.fromAHSV(…).toColor()` + `HSVColor.fromColor(…).hue`，与产品代码同一公式；色相距按 SR2-56 测试的做法取生成色实际 hue）复算 13–30 科：

  | 科 | 色相 | 颜色 | 步进 | 耗尽 36 步 | 最小色相距 |
  |----|------|------|------|-----------|-----------|
  | 13 | 284.0° | `0xFFB34CD9` | 2 | 否 | 31.8° |
  | 14 | 135.5° | `0xFF4CD970` | 4 | 否 | 31.8° |
  | 15 | 17.0° | `0xFFD9744C` | 36 | **是** | 14.0° |
  | 16 | 154.5° | `0xFF4CD99D` | 36 | **是** | 12.7° |
  | 17 | 292.0° | `0xFFC64CD9` | 36 | **是** | 8.1° |
  | 20 | 344.5° | `0xFFD94C70` | 36 | **是** | 5.0° |
  | 23 | 37.0° | `0xFFD9A34C` | 36 | **是** | **0.7°** |
  | 30 | 279.5° | `0xFFA94CD9` | 36 | **是** | 4.3° |

  15–30 科全部耗尽 36 步（仅 25 科 18.5°、其余均 < 15°）。根因是 37° 步进的格点有限：14 色各占 50° 禁区后，36 个格点全部落在禁区内——不是步进次数不够，而是步进格点本身撞墙。
- 修的方向：二选一，(a) 耗尽后不再原样返回，改在 1° 细粒度上扫描取“与全部已用色最小色相距最大”的色相（14 色下理论最优仍有约 12–13° 空隙，至少做到最优而非任意）；或 (b) 明确降级语义：耗尽时放宽阈值（如 10°）并在代码注释写明“15 科后 25° 不可达”。无论哪种，补一个 14–16 科的用例钉住“耗尽不静默返回违规色”（现有 SR2-56 只钉第 13 科）。

## SERVICES-2（P2）— SR2-35：QmChip × 区上下各留约 1.55px 死区，“整个芯片都可点”不成立

- 位置：`lib/widgets/uikit.dart:650-690`（`QmChip` 双区分支 `Row`）。
- 现象：标签区识别器高 = 文字 13×1.2 + 上下各 4 = 23.6px，× 区识别器高 = 字形 12.5×1 + 上下各 4 = 20.5px；`Row` 默认 `crossAxisAlignment: center`，行高取 23.6px，× 识别器上下各留 (23.6 − 20.5) / 2 ≈ **1.55px**（1.0 倍字号；1.3 倍字号下约 2px）不被任何识别器覆盖。双区模式下外层 `_QmPressable` 不装 Tap 识别器（`childHandlesTap: true`），所以点这条细缝**无回调**，但外层 `Listener` 仍会给出按压视觉——正是 SR2-35 要消灭的“按下无反应 + 有按压闪烁”，以缩小版残留。SR2-35 测试只点 `chipRect.center.dy`（垂直居中）与标签/× 间隙中点，探不到这条缝。
- 证据：尺寸算式——旧布局总宽 12 + 文字 + 4 + 字形 + 12、总高 23.6px，与新布局逐项相等（芯片总尺寸不变的说法属实）；但旧布局死区由外层 `_QmPressable` 的 `onTap` 兜底（点缝触发标签回调），新布局外层无手势，缝变成真死区。`deletableChipPaddingH/V` = 12/4（`design_tokens.dart:502-503`），`chipFontSize` = 13、`captionFontSize` = 12.5、`controlLineHeight` = 1.2（`:439/468/483`），`QmGlyph` 的 `Text` 行高恒为 1（`uikit.dart:105-113`）。
- 修的方向：`Row` 加 `crossAxisAlignment: CrossAxisAlignment.stretch`（两识别器撑满行高），或给 × 识别器的 `Padding` 外包一层与标签区等高的 `SizedBox`；补一个探针用例点 × 区顶部/底部边缘（`chipRect.top + 1` 与 `chipRect.bottom - 1` 处 × 的横坐标）断言 `deleted` +1。

## SERVICES-3（P2）— SR2-73：测试屏障以 error 完成时，`_loadFuture` 被永久毒化，后续检测不再重试加载

- 位置：`lib/services/yolo_onnx_service.dart:225-245`（`_ensureLoaded` / `_loadOnce`）。
- 现象：`_loadOnce` 里 `await gate.future` 在 `try` 块之外；若 gate 以 error 完成，`_loadOnce` 的 Future 以 error 完成，`_ensureLoaded` 的 `await future` 抛错，`if (!ok) _loadFuture = null` 一行被跳过——失败的 `_loadFuture` 永远留在原地。此后每次 `_ensureLoaded` 都直接返回同一个失败 Future，每次检测都走 fallback，且 `_loadAttempts` 不再增长，**加载永不重试**，直到重启或调 `resetLoadStateForTest`。
- 证据：临时探针实测——gate 先 `completeError(StateError)`：第一次检测 fallback、`loadAttempts == 1`；第二次检测仍 fallback、`loadAttempts` 仍为 1（`POISONED=true`）。对照：正常加载失败（模型缺失）走 `try` 块内路径，`_loadFuture` 会被清掉，下次检测会重试（SR-P1-16 行为不受影响）。
- 定级说明：生产 `loadGateForTest` 恒为 null（全仓 grep：除 `yolo_onnx_service.dart` 本身外只有 `test/yolo_onnx_service_test.dart` 引用它，见“已确认无问题”），所以生产不可达；风险只在测试侧——将来某个测试给 gate 包超时/取消并以 error 完成时，会毒化之后同文件的所有测试。修的方向：把 `await gate.future` 移进 `try` 块内，或在 `_ensureLoaded` 里用 `future.then((ok) { if (!ok) _loadFuture = null; }, onError: (_) => _loadFuture = null)` 清掉失败的 future。

## SERVICES-4（P2）— SR2-73：串行队列无超时，单次推理卡死会堵住后续全部检测

- 位置：`lib/services/yolo_onnx_service.dart:153-165`（`_detectQueue` + `_serializedDetect`）。
- 现象：`_serializedDetect` 把每次 `_detect` 链在一条静态 Future 链上，没有任何超时或取消。若某次原生 `runAsync` 迟迟不回（驱动/模型异常），该次检测挂起的同时，**之后所有检测也永久排队**——第六批之前，一次卡死的推理只卡住自己的调用方；改动后它会放大成全局检测停摆。链本身不会被失败毒化（`run.then<void>((_) {}, onError: (_) {})` 已吞掉错误，后续检测仍能跑——这一点已静态核对，无问题），缺的是“卡死”这一分支。
- 证据：代码阅读——`_detect` → `_run` → `session.runAsync` 全程无 `timeout`；`detectPage` 也无超时。属于新引入的失效模式放大，发生概率低（`runAsync` 卡死本身是假设场景），故 P2。
- 修的方向：给队列里的单次推理加超时（如 60s，超时按推理异常走 fallback 并放行队列），或在报告里写明“接受此风险：单次推理卡死即全部检测停摆”作为已知取舍。注意不要把超时做成取消原生推理（onnxruntime 无取消语义），超时只应放行队列、不应假装推理已结束。

## SERVICES-5（P2，非第六批引入 · B2 遗留）— SR2-36 口径外仍有一处直接返回存色：错题本紧凑行在深色下用亮色存色画学科名

- 位置：`lib/modules/wrongbook/wrongbook_list.dart:942-945`（`_prowMetaLine`）。
- 现象：`DesignTokens.subjectInk(q.subjectId, Brightness.light, subject.color)` 把亮度写死成 `Brightness.light`。`subjectInk` 在亮色分支下对新学科直接返回 `stored` 原值——于是深色主题里，错题本紧凑行 / 归档行的学科名仍是饱和亮色存色（如化学紫 `0xFF7C5CFC`），与 SR2-36 刚修掉的 `subjectLabelColor` 第三入口是同一类缺陷，只是换了个入口。
- 来源说明：**不是第六批引入的**——该行自 B2 起就在（注释“B2 补充”），第六批未动此文件此行；列在这里是因为本次任务点名要求“逐一核实全部调用点”，它是 13 处存色调用点里唯一未雾化的一处。其余 12 处（`home_page.dart:644-647`、`report_page.dart:673`、`review_page.dart:1118/1395`、`subjects_page.dart:631/651/724`、`uikit.dart:566/590`、`app_shell.dart:528`、`widgets.dart:751`）全部传真实 `brightness`，深色下均走雾化，已逐一核对。
- 修的方向：把 `Brightness.light` 改成 `Theme.of(context).brightness`（与同文件注释“纸面取浅色档”的意图冲突时以 SR2-36 口径为准，深色下雾化）；建议作后续项而非第六批回炉，因为它不在第六批改动文件清单的修法内。

---

## 已确认无问题

### YOLO 串行化（SR2-73 核心）

- **真机实测有效**：`test/yolo_onnx_service_test.dart` 单文件实跑 27/27 通过（含 SR2-73 真实模型并发用例：两次并发检测均 `usedFallback == false`、`lastDetectStats` 非空）。另写 4 路并发真模型探针（4 个不同实例、4 张图同时发起）：4 次全部成功、`stats` 齐全，**无 SIGSEGV**。模型与原生库均在本机存在（`assets/models/question/yolo11s-question-v1.onnx` 38MB、`onnxruntime-1.4.1/linux/libonnxruntime.so.1.15.1`）。
- **链不会被失败毒化**：`_detectQueue = run.then<void>((_) {}, onError: (_) {})` 吞掉上一次推理的错误，后续检测仍能跑；`_detect` 是 async 函数，不会同步抛错。静态核对无问题。
- **加载与队列无死锁**：并发检测先合流到同一个 `_loadFuture` 再依次进推理队列；加载不依赖队列、队列不反向等加载。`_ensureLoaded` 的先查 `_loadOk` 再查 `_loadFuture` 再建 `_loadOnce` 是同步连续动作，Dart 单线程下无“两次加载”竞态；`_loadAttempts` 只在 `_loadOnce` 入口同步自增，计数可信。
- **并发检测在加载未完成时的行为**：第二次检测加入第一次的 `_loadFuture`（测试断言 `loadAttemptsForTest == 1`，实跑通过），加载成功后两次推理依次执行。

### 测试可观测性入口（SR2-73 遗留确认）

- **生产门禁恒为 null 属实**：全仓 grep——`loadGateForTest` / `loadAttemptsForTest` / `resetLoadStateForTest` 除 `lib/services/yolo_onnx_service.dart` 自身外，只在 `test/yolo_onnx_service_test.dart` 出现；`lib/` 下无任何生产代码设置 gate、读计数或调重置。`@visibleForTesting` 是注解级约束，与 Flutter 惯例一致。
- SR2-73 用例的 500ms 经验余量（GAPS.md 已记为遗留）：本次实跑两次均通过；若极慢解码环境下抖动，优先把等待改长、不改生产屏障逻辑——与 GAPS.md 结论一致，不重复编号。
- GAPS.md 的“全盘无 Flutter SDK”误判已在 B6-SUMMARY 纠正：SDK 在 `~/workspace/flutter-install/flutter/bin/`（3.47.9），本次全部实跑均走该绝对路径。

### SR2-31 / SR2-56（金角，第 13 科）

- 独立复算属实：第 13 科金角起点 210° 距数学蓝 216.6° 为 6.6°、步进 247° 距靛蓝 238.7° 为 8.3°、再步进 284° 距最近的紫 252.0° 为 32.0°（按生成色实际 hue 283.8° 算为 31.8°，与报告一致）；`HSV(284, 0.65, 0.85)` = `0xFFB34CD9`，与 SR2-56 字面值断言一致。第 14 科亦合规（135.5°，最小色相距 31.8°）。25° 阈值与 31.8° 的算法本身没错，问题只在 15 科后的兜底（SERVICES-1）。

### SR2-36（雾化第三入口）

- `subjectLabelColor`（`widgets.dart:727-751`）委托正确：非预设学科有 `stored` 时亮色返回存色原值、深色走 `DesignTokens.subjectColor` 的同一雾化；预设三科与无 `stored` 分支不动。`subjects_page.dart:43` 注释已同步。
- 全仓 13 处存色调用点已逐一核对（见 SERVICES-5），除那一处 B2 遗留外全部雾化。

### SR2-35（芯片检测区）

- 芯片总尺寸不变属实：新旧布局逐项相等（宽 12 + 文字 + 4 + 字形 + 12；高 13×1.2 + 8）。单区（只有 `onDelete` 或只有 `onTap`）分支由内层 `Padding` 补回同款内边距，外观不变。
- 与 SR-P2-52/55 裁决无冲突：那两项是错题本封面字号缩放（只乘字距）与封面选择器点按（保留外层），与 `QmChip` 双区手势无关；芯片改动不碰封面代码。
- 残留死区见 SERVICES-2（× 区上下约 1.55px）。

### SR2-24（题内框只取切片来源父框）

- 逻辑正确（`widgets.dart:84-118`）：按 id 比对父框，`parentBoxId` 为空回退首个框、指向其他父框的跳过；`layer1ById` 与 `firstLayer1` 的构建无误。两个新用例（同区域跨父框比面积取首个框下者；只有非首个父框下内框时不出结果）与实现一致。
- `parentBoxId` 指向不存在的 id 时回退首个框——与第六批前（SR-P2-23）的回退行为相同，本次未改，不另计。

### SR2-38（`minSize: false` 只改检测路径）

- 核实全部调用点：`minSize: false` 只在三处——`_toPageBox`（检测输出）、`box_editor.dart:507`（`_ingestDetected`，检测结果入编辑器）、`box_editor.dart:781`（修框复原，把检测出的 `picked` 框换回 1 层框，SR2-20 流程）。三处都是检测来源的框；用户手画 / 拖动 / 缩放的其余调用点全部走默认 `minSize: true`，行为未变。负坐标用例（`w` 扣到 0.3、`h` 扣到 0.4；默认分支仍 0.5）与实现一致。

### SR2-55（雾化字面值断言）

- 独立验算三组雾化色（Dart `Color.lerp` 的逐通道 round 语义，含 241.5 → 242 的舍入）：`0xFF2E7CF6` → `0xFF7CAAF2`、`0xFFEF4444` → `0xFFE68C90`、`0xFF7C5CFC` → `0xFFA799F5`，与测试字面值与注释完全一致。`.toARGB32()` 断言的取舍正确（`Color.lerp` 产出带小数通道，`Color==` 会误判）。

### SR2-54 / SR2-63 / SR2-77 / SR2-78（测试是否真测产品行为）

- **全部测的是真实产品代码，不是 mock**：
  - SR2-54：真实 `ImportService.enqueue` + 稀疏填充文件把占用顶到 2GB−1MB，断言任务 `failed` 且错误含 `2GB`；边界判定是产品代码（`import_service.dart:277/519` 的 `used + … > maxStorageBytes`）。唯一替身是 PDF 页数引擎（假引擎页数恒为 1），那是既有测试脚手架，不影响边界判定本身。
  - SR2-63：真实 `CompactSliceThumb` / `QuestionSlice` 泵进不同 dpr，读真实 `Image.cacheWidth`：dpr 1.0 得 128/320，dpr 4.0 得封顶 384/2048。
  - SR2-77：真实 `enqueue` + 真实 `onProgress` 回调，5MB 按 64KB 分块复制，`pct = copied*70~/total` 每步进 0 或 1，故 0→70 每个整数都会出现；`reported.length >= 71` 且末值 100 的断言成立。
  - SR2-78：真实 `readZip`，在 `buildZip` 合法包上手改字节；偏移量核对过产品解析：ZIP64 判的是中央目录 `rawSize` 字段（`cd+24`，`zip_archive.dart:343-348` 三字段任一 `0xFFFFFFFF` 即拒）、多盘是 EOCD 盘号（`eocd+4`）、注释长度是 EOCD `+20`；“注释长度与文件末尾对不上才拒、格式正确的注释可读”的区分与 `readZip` 实现一致。

### SR2-13（% 徽标）

- 在真实放大对话框里读 `%` 徽标：点 ＋ 变大、点 － 变小、对话框仍在；比只断言对话框存在更能钉住缩放重置 bug。正则 `^\d+%$` 在该对话框内只会命中徽标，无歧义。
