# Batch 6 · P2 服务层 / 主题 / 组件（执行员 D-services）

- 日期：2026-11-15
- 范围：SELF-REVIEW-2 的 SR2-24、SR2-31、SR2-35、SR2-36、SR2-38（产品修法 5 项）+ SR2-13、SR2-54、SR2-55、SR2-56、SR2-63、SR2-77、SR2-78（测试补项 7 项）
- 只改的文件：`lib/widgets/widgets.dart`、`lib/widgets/uikit.dart`、`lib/modules/subjects/subjects_page.dart`、`lib/services/yolo_onnx_service.dart`；`test/subjects_page_test.dart`、`test/b5_p2_services_test.dart`、`test/yolo_onnx_service_test.dart`。未提交、未推代码。

## 产品修法

### SR2-24 — `realRegionRects` 跨父框比面积（`lib/widgets/widgets.dart:84-118`）

- 修法（按规定第一种）：只取切片来源父框（首个 1 层框）下的内框参与比较。`parentBoxId` 为空的老数据行仍回退到首个框（算它的）；指向其他父框的内框直接跳过（`:112` `if (source.id != firstLayer1.id) continue;`，按 id 比，不依赖对象同一性）。函数头注释补 SR2-24 说明。
- 测试：`test/b5_p2_services_test.dart:731` 新组“SR2-24 realRegionRects”2 个用例——(1) 两父框同区域 stem：b1 下换算面积 0.04，b2 下换算面积 0.16，断言胜者是 b1 下的 `Rect(0.2, 0.2, 0.2, 0.2)`；(2) 只有非首个父框下的内框时该区域不出结果（调用方回退示意框，不回退错位框）。
- 出入：任务要求测试补在 SR-P2-24 组（`test/b5_p2_collect_test.dart`，不在本批可改文件清单内），故新组放在本批可改的 `test/b5_p2_services_test.dart` 里；原 SR-P2-24 组（b5_p2_collect）未动。

### SR2-35 — `QmChip` 双区芯片点按死区（`lib/widgets/uikit.dart:624-690`）

- 修法（按规定方案 a）：标签区的 `GestureDetector` 包住含左内边距的区域（padding 移进标签识别器内：左 12 / 上下 4 / 右 4，间隙归属标签区），× 识别器热区向外扩到右内边距（左 0 / 上下 4 / 右 12）。`Container` 本身不再另设 padding，单区（只有 `onDelete` 或只有 `onTap`）分支改由内层 `Padding` 补回同款内边距；芯片总尺寸不变。外层 `_QmPressable` 的 `Listener` 按压视觉保留——现在每次按压都有对应回调，不再“按下无反应 + 有按压闪烁”。
- 测试：`test/b5_p2_services_test.dart:570` 新用例“SR2-35：点左内边距与标签/× 间隙也触发标签回调”——点 `rect.left + 3`（自审探针点位）与标签/× 间隙中点，断言 `tapped` 各 +1、`deleted` 保持 0。

### SR2-36 — `subjectLabelColor` 深色下仍返回存色（`lib/widgets/widgets.dart:727-751`）

- 修法（按规定）：非预设学科、有 `stored` 时直接委托 `DesignTokens.subjectColor(subjectId, brightness, stored)`（`:751`）——亮色返回存色原值，深色走与 `subjectColor` / `subjectInk` 同一雾化（45% 混 `#DCE3EC`），不再造第三份规则。预设三科与无 `stored` 的查表分支不动。函数头顶的过期文档注释已同步改掉。
- 另：`lib/modules/subjects/subjects_page.dart:43` 的过期注释（“亮/深两主题都直接用存色画圆点”）已改掉，改为“圆点亮色用存色、深色走 `DesignTokens.subjectColor` 的雾化（SR2-36）”。注释，不影响行为。
- 测试：`test/b5_p2_services_test.dart:416` 新 widget 用例——深色主题下 `subjectLabelColor(context, 'chemistry', 0xFF2E7CF6)` 为字面值 `0xFF7CAAF2`（自审探针的期望值），亮色下仍为存色原值。

### SR2-38 — `clampToPage` 保留旧钳制模式（`lib/services/yolo_onnx_service.dart:565-624`）

- 修法（协调员定夺 a）：只给检测路径（`minSize: false`）改成交集语义（`:578-590`：框与 `[0, 1]` 页面求交，左/上溢出扣宽/高，如 `x=-0.2, w=0.5 → x=0, w=0.3`）；编辑器路径（默认 `minSize: true`）保持现状（左上角收到 0、尺寸不变，框被拖出页边时不静默缩小）。重建框的公共部分抽成 `_rebuildClamped`（`:605-624`），其余字段原样保留。`rotateBoxToRotatedPage` 未动。
- 测试：`test/yolo_onnx_service_test.dart:81` 的“负坐标”用例按 `minSize` 分两组重写——`minSize: false` 时 `w` 扣到 0.3、`h` 扣到 0.4；默认时 `w`/`h` 仍为 0.5。

### SR2-31 — 金角生成色与既有色近乎撞色（`lib/modules/subjects/subjects_page.dart:61-68, 307-340`）

- 修法（Meng 已定 25° 阈值）：生成色与全部已用色算环形 hue 距离（新增顶层 `_hueDistance`，0..180°），小于 25° 或精确撞色时继续步进 37°，直到拉开；步进上限由 12 次放宽到 36 次（37° 步进、25° 阈值下两步即拉开，36 次是兜底，不会死循环）。
- 实算：第 13 科金角起点 210° 距数学蓝 216.6° 仅 6.6°，步进 247° 距靛蓝 238.7° 仅 8.3°，再步进 284° 距最近的紫 252.0° 为 31.8°，接受；生成色 `HSV(284, 0.65, 0.85)` = `0xFFB34CD9`（纯 Dart 复算 `HSVColor.toColor` 公式验证，与自审报告的 hue 实算一致）。

## 测试补项

### SR2-13 — 放大对话框只断言对话框还在（`test/b5_p2_services_test.dart:708`）

- 在原 SR-P2-75 用例内读 `%` 徽标：点 ＋ 前后断言百分比变大，点 － 后断言变小，对话框仍在。

### SR2-54 — SR-P2-59 只测放行侧（`test/b5_p2_services_test.dart:231`）

- 新用例：稀疏填充把占用顶到 2GB−1MB，2MB 的 PDF，断言任务失败且错误含 `2GB`（走导入前估算：`used + fileSize > 上限`，错误为“空间不足：题库文件已超过 2GB 上限……”）。

### SR2-55 — SR-P2-66 期望色用与实现相同的公式（`test/b5_p2_services_test.dart:391`）

- 期望值改写为算好的字面色值：`0xFF2E7CF6` 雾化后 `0xFF7CAAF2`（(124, 170, 242)，与自审探针值一致，纯 Dart 复算 `Color.lerp` 舍入验证）；补第二个输入色——饱和暖红 `0xFFEF4444`，`subjectColor` 与 `subjectInk` 深色下均为字面值 `0xFFE68C90`（(230, 140, 144)），亮色下仍为原值。

### SR2-56 — SR-P2-51 第 13 科只断言“不相同且不是数学蓝”（`test/subjects_page_test.dart:686`）

- 断言第 13 科颜色字面值 `0xFFB34CD9`；补生成色与全部 12 个已用色的环形 hue 距离断言，阈值 25°（实测最小 31.8°）。

### SR2-63 — SR-P2-74 只测 dpr=3.0（`test/b5_p2_services_test.dart:635`）

- 新用例：dpr=1.0 对照——`CompactSliceThumb` 128、`QuestionSlice` 320；dpr=4.0——`CompactSliceThumb` 128×4=512 → 封顶 384，`QuestionSlice(maxHeight: 480)` (480×2)×4=3840 → 封顶 2048。

### SR2-77 — SR-P2-62 “UI 回调仍逐次”只断言 `length > 2`（`test/b5_p2_services_test.dart:358`）

- 改为断言回调序列含 0→70 的连续百分比（逐个 `contains`），另断言 `reported.length >= 71` 且末值 100。依据：5MB 文件按 64KB 分块复制，`pct = copied*70~/total` 每块步进 0 或 1，每个整数百分比都会出现；其后渲染段与收尾再报 100。

### SR2-78 — SR-P2-68 ZIP64 / 多盘 / EOCD 带注释的拒绝路径无用例（`test/b5_p2_services_test.dart:813`）

- 新组 4 个用例（`buildZip` 合法包上手改字节；帮手 `_zipFind` / `_zipFindLast` / `_zipWriteU16` / `_zipWriteU32` 在 `:155-191`）：(1) 中央目录 `rawSize` 改 `0xFFFFFFFF` → 拒，含 `ZIP64`；(2) EOCD 盘号改 1 → 拒，含 `多盘`；(3) EOCD 注释长度写 10、实际只补 3 字节 → 拒，含 `找不到中央目录`；(4) EOCD 带格式正确的注释（长度 5 + `hello`）仍可读的对照。
- 出入两点：(a) 原 SR-P2-68 组在 `test/b5_p2_data_test.dart`（不在本批可改文件清单内），故新组放在本批可改的 `test/b5_p2_services_test.dart` 里，未动原组；(b) “EOCD 带注释”本身不是拒绝项——`readZip` 的 `_parseCentralDirectory` 明确支持格式正确的 EOCD 注释（按注释长度校验到文件末尾），所以第 (3) 个用例写的是“注释长度与文件末尾对不上”的拒绝路径，第 (4) 个对照用例钉住“格式正确时可读”这一实际语义，避免后人误把注释当成拒绝条件。

## 验证

- `flutter analyze`（7 个改动文件）：**0 问题**。
- 全仓 `flutter analyze`：7 个问题，但全部在责任文件之外——`test/review_page_test.dart:937`、`:954`，`test/wrongbook_page_test.dart:1708/1743/1777`（4 个 `const_with_non_const` error），`lib/modules/collect/collect_page.dart:457`（`_lastSplitStamp` 未用，warning + info）。我未碰这些文件，问题与本次改动无关，请总协调转交对应执行员。
- 测试：按任务要求只尝试跑一次。`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux flutter test --concurrency=1 test/b5_p2_services_test.dart` 在构建阶段即失败，未跑到任何用例：`pdfium_dart-0.4.2` 原生资源构建报 `No compiler configured on host 'linux_x64'`（clang/ninja 在 VM 替换后丢失）。未自行修复工具链。三个测试文件均未跑通，需工具链恢复后由总协调补跑全量验证。
- 未跑测试的代偿校验（静态）：纯 Dart 脚本复算 `HSVColor.toColor` / `Color.lerp` / 环形 hue 距离——第 13 科 `0xFFB34CD9`、最小 hue 距 31.8°、雾化蓝 `0xFF7CAAF2`、雾化暖红 `0xFFE68C90`、SR2-24 切片坐标 `(0.2, 0.2, 0.2, 0.2)` 全部与测试期望值一致。
- `dart format --set-exit-if-changed`：本批 7 个文件中有 4 个（`yolo_onnx_service.dart` 与 3 个测试文件）报格式出入，但出入遍布未动行（如 `yolo_onnx_service.dart:49-50`、`test/subjects_page_test.dart:15` 的 `_tq`），是全树既有风格与当前 SDK formatter 不一致，非本次改动引入；本次新增行沿用文件既有风格，未整文件格式化（避免产生无关大 diff）。`lib/widgets/widgets.dart`、`lib/widgets/uikit.dart`、`lib/modules/subjects/subjects_page.dart` 三处产品改动行无新增格式出入。

## 遗留问题

- 全部新增/改写测试均未实际跑过（工具链原因，见上），待补跑。重点关注：SR2-35 的 `tester.getRect(find.byType(QmChip))` 取芯片外框、SR2-13 的徽标正则 `^\d+%$` 查找、SR2-77 的 0→70 连续回调（依赖 64KB 分块步进）、SR2-78 的 EOCD 注释长度篡改。
- SR2-38 的 `minSize: true` 分支里 `(minSize && …)` 判断现恒为真（`!minSize` 已提前返回），留作原样以保持 diff 最小；如后续整理可简化。
- SR2-31 的金角步进上限 36 次是兜底；12 色用完后的第 14、15…科生成色同样受 25° 阈值保护，但未逐个断言字面值（只在第 13 科钉死）。
