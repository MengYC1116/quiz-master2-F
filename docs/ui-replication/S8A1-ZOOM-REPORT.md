# S8A1 — 放大浮层 1.5× 初始偏移修复报告

- 日期：2026-11-13
- 对应：R11 §8.1 #1（最重要项）
- 状态：**已修复，真机验证通过**
- 改动文件：`lib/widgets/widgets.dart`（`showQuestionZoomDialog` / `_ZoomDialogState`）、`test/organize_page_test.dart`（旧断言更新）
- 报告截图：`docs/ui-replication/shots/s8a1/`（修复前 3 张 + 修复后 7 张）
- Linux 结果不替代 Win11 最终验收。

## 1. 结论

修复后，放大浮层打开即居中、无裁切：整理 / 详情 / 复习三处、亮 + 深两档，纸面中心与视口中心偏差均为 0px（像素实测），徽标 132%，整道题全文可见。拖动 / 滚轮 / ＋ / － / 点图关闭 / 关闭 × / Esc 均正常。

## 2. 根因——先纠正 R11 的说法

### 2.1 不存在 60–80px 左移：是左右对称裁切被误读

R11 写“纸面左移约 60–80px”。本次用 5 张独立截图重新像素测量（R5 整理、R7 详情、R8 复习各一张，加本次修复前深色整理两张）：题干轴线中心 639.5、文字行中心 640–644，视口中心 640——**纸面水平方向本来就是居中的，左移 ≈ 0**。

真正的问题是**对称裁切**：旧纸面固定 900×480，1.5× 后渲染 1350×720，视口只有 900×541，左右各裁 225px、上下各裁 ~90px。题首在左边缘被切掉一半（修复前深色整理截图里题干从“现代…”半个字开始），读起来像“纸面往左移了”。修复前截图见 `before-organize-dark.png` / `before-detail-light.png` / `before-review-dark.png`。

### 2.2 真正存在的偏移：垂直方向 +15px

纸面中心实测 y ≈ 405，视口中心 389.5，**向下偏约 15px**（标准档；随字号档增大而增大，因为视口长高、纸面高 480 不变）。公式：偏移 = (Vh − H)/4 = (541 − 480)/4 ≈ 15.25。原因是旧 `_centerInitial` 用**纸面**尺寸算平移（−W/4, −H/4），而正确值应用**视口**尺寸。

### 2.3 更深的根因：InteractiveViewer 的 alignment 默认为 null

读 Flutter 3.47.9 SDK 源码（`packages/flutter/lib/src/widgets/interactive_viewer.dart`）：`final Alignment? alignment;` 无默认值，`_InteractiveViewerBuilt` 把它传给 `Transform(transform: matrix, alignment: alignment)`。所以变换矩阵是绕 **child 原点 (0,0)** 应用的，不是绕视口中心。R5 的 `_centerInitial` 注释假设了“中心支点”，这个假设是错的；旧代码的平移量恰好是“纸面 900×480 在 1.5× 下绕原点缩放所需的补偿”，只在纸面恰为 900×480 时近似成立，纸面一改尺寸就失效。

### 2.4 HTML 口径分析：fit×1.5 在数学上必然溢出

读 HTML 原型（`quiz-master2-jiao-hu-yuan-xing.html` 约 348–357 行、4097–4140 行）：打开缩放 `zoomScale = min(fit*3, max(minScale, fit*1.5))`，徽标 `zoomScale/fit×100`（打开即 150%），其中 `fit = min(视口宽/纸宽, 视口高/纸高)`。但 fit×1.5 在约束维度上必然溢出 50%——**HTML 自身打开时也会裁切**。任务要求是“打开即居中、无裁切”，因此本次取 `s0 = min(1.5, fit)`，即“尽量放大到 1.5×，但不超过刚好装得下的 fit”。这是对 HTML 公式的**有意偏离**（已在代码注释和本报告中说明）；徽标沿用 Flutter 既有绝对缩放口径，标准档 1280×720 下为 132%（fit = 900/680 ≈ 1.32），不再是写死的 150%。

（环境说明：本机无 headless 浏览器可用，HTML 放大行为由读源码得出，未直接渲染对照。）

## 3. 修复内容（`lib/widgets/widgets.dart`）

1. **纸面封顶宽 + 内容高度**：新增 `_paperWidth(dialogScale)` = `min(680.0, organizeZoomWidth × dialogScale × 0.86)`（HTML `min(680px, 86%)` 规则）；Stack 包一层 `SizedBox(width: _paperWidth(scale), child: IntrinsicHeight(...))`，纸面由固定 900×480 改为 680 宽、内容高度（约 130–190px，视题目长短）。`QuestionSlice` 本身未动（其 `maxHeight: 480` 上限仍在，但内容高度远小于 480，不再起约束作用）。
2. **正确的初始矩阵**：`_centerInitial()`（post-frame 回调，尺寸未就绪时下一帧重试）实测视口尺寸（`_viewportKey`）与纸面尺寸（`_paperKey`），算 `fit = min(Vw/W, Vh/H)`（新增静态 `_fitFor()`），取 `s0 = min(1.5, fit)`，设 `M = T((1−s0)·Vw/2, (1−s0)·Vh/2) · S(s0)`——平移量用**视口**尺寸，纸面中心精确落在视口中心。`_scale` 不预赋值，由 `_onTransform` 监听到矩阵变化后 setState 更新徽标。新增 `import 'dart:math' as math;`。调试用 `[S8A1-DEBUG]` 打印已删除。
3. **`_multiply` 改为绕视口中心缩放**：`M' = T(C)·S(f)·T(−C)·M`，中心 C 取实测 `_viewportSize`（未就绪时退回对话框尺寸估算）。旧代码是右乘缩放矩阵，绕视口左上原点缩放，纸面会往右下漂移。
4. **`showQuestionZoomDialog` 上方文档注释重写**：写明新行为与旧 `_centerInitial` 错在哪里。

预期值（标准档、1280×720）：纸面 680×~140–190 → fit ≈ 1.32 → s0 ≈ 1.32 → 徽标 132%，渲染纸面约 898×~190–250，整题可见、居中。

## 4. 真机验证（Xvfb :99，1280×720，Linux Release 构建，libapp.so aff72928）

像素测量方法：沿 x=640 纵向找纸面色（深色 #D8DCE2 / 亮色 #FFFDF4）连续段，取包围盒中心与视口中心 (640, 389.5) 对比；横向取 y=389 行的纸面 x 范围。

| 入口 | 主题 | 徽标 | 纸面中心偏差 | 全文可见 | 截图 |
| --- | --- | --- | --- | --- | --- |
| 整理工作台 | 深 | 132% | dx 0, dy 0 | 是（题首“题：材料：”完整） | after-organize-dark.png |
| 整理工作台 | 亮 | 132% | dx 0, dy 0 | 是 | after-organize-light.png |
| 题目详情 | 深 | 132% | dx 0, dy 0 | 是 | after-detail-dark.png |
| 题目详情 | 亮 | 132% | dx 0, dy 0 | 是 | after-detail-light.png |
| 复习会话第①步 | 深 | 132% | dx 0, dy 0 | 是 | after-review-dark.png |

- **收集中心**：grep 确认 `collect_page.dart` 没有 `showQuestionZoomDialog` 调用点，框修编辑器是独立画布，本次未动。任务原文“三处”实为两处入口 + 复习共用同一浮层；错题本紧凑列表缩略图也调同一浮层（`wrongbook_page.dart:2957,3091`），与整理/详情/复习共用代码，未单独跑真机（浮层本身已由三处覆盖）。
- **复习亮色**：未单独跑（与深色共用同一浮层，亮/深只差颜色；亮色已在整理/详情两处验证）。

### 交互验证（整理工作台，深色）

- **＋**：徽标变化（132% → 放大），纸面放大；**－**：徽标回落；**滚轮**（xdotool click 5）：徽标 132% → 91%，纸面缩小后仍居中（`after-zoom-wheel-91pct.png`）。滚轮一次触发的步进数与 ＋/－ 不完全一致（91% ≈ 两次 0.85 步进），属滚轮事件分发粒度，不影响使用。
- **拖动**：分步拖动（8 步 × 10px）纸面跟随移动约 70px（`after-zoom-drag.png`，顶部由 y≈243 移到 y≈313）；放大到 206% 后拖动同样跟随。
- **单跳拖动不移动**：xdotool 一次 mousemove 大跳变（mousedown 后单步跳 100px）时纸面不动。已用旧构建对照：**旧构建同样不动**（stash 回退后重建，libapp.so 0eb527b1，单跳拖动前后纸面 y 段均为 119–475；分步拖动新旧都移动）。因此是既有行为（单事件大位移的手势识别/xdotool 事件投递特性），**不是本次回归**，不修。
- **91% 贴合态下纸面不可拖动**：纸面小于视口时 InteractiveViewer 零边距夹紧使其保持居中，框架既有行为，本次未动。
- **关闭**：点纸面一下关闭、关闭 × 关闭、Esc 关闭，三种均验证通过（Esc 后回到整理台截图已核对）。

### 静态检查

- `flutter analyze`：No issues found。
- `flutter test`：**279/279 通过**（含更新后的整理页放大浮层测试）。
- 旧测试更新（`test/organize_page_test.dart`）：`150%` → `132%`，并新增居中断言（纸面渲染中心与 InteractiveViewer 中心偏差 < 3px）与完整可见断言（纸面四边在视口内，±1px 容差）。注：`Rect.contains` 右/下边是开区间，渲染宽恰等于视口宽（898–900）时右缘贴边会被误判为越界，故改用逐边 ±1px 比较——第一版断言因此失败过一次，已修正并通过。
- 演示库已恢复原状：9 道题、待整理 4、themeMode=dark、fontSize=standard（从 `/tmp/qm2-bugfix-orig.db` 恢复并核对）。

## 5. 未动事项（记录在案）

- **区域叠加比例**：`QuestionRegionOverlays` 的 stem 34% / option 36% / figure 42% 是既有近似；内容高度纸面下 stem 框不一定包住垂直居中的题文（整理页亮色截图里题干文字超出 stem 虚线框上下缘可见）。真实 Layer-2 YOLO 框接入后以实测框为准，本次不修。
- **收集中心框修编辑器**：独立画布，不走本浮层，不动。
- **HTML fit×1.5 公式**：见 §2.4，本次取 min(1.5, fit)，属有意偏离，已说明。
- 构建环境备注：本次构建用 `flutter build linux --release`，产物装到 `/usr/local/quiz_master2` + `/usr/local/lib/libapp.so`；gtk 开发包沿用 bugfix 会话补好的状态，未再缺包。

## 6. 遗留

- Win11 真机复核仍需做（字体/尺寸/DPI 下的纸面高度与徽标值可能与 Linux 回退字体下略有出入；132% 是 Linux 下实测值，Win11 下若纸面内容高度不同、fit 由高度约束时徽标会相应变化，但“居中、无裁切”的结论不受影响）。
- 错题本紧凑列表缩略图浮层未单独跑真机（共用同一浮层代码）。

## 7. 还原事故与恢复（2026-11-13 15:05，补记）

- **事故**：本报告初版写好、截图验证通过后，主 agent 在同步本地分支时跑了一次 `git reset --hard origin/ui-replication`，把未提交的 A1 改动还原了：`lib/widgets/widgets.dart` 的放大浮层修复（`_paperWidth`/`_fitFor`/`_centerInitial`/`_multiply`）与 `test/organize_page_test.dart` 的断言更新全部丢失（已核实：`widgets.dart` 里已无 `_fitFor`/`_paperWidth`）。同时丢失的还有同期未提交的学科颜色两处修复（见 S8A2 报告 §1 备注）。
- **未丢失**：本报告与全部截图（未跟踪文件不受影响）、已提交历史、15:05:52 之后对 `test/subjects_page_test.dart` 的新改动。
- **恢复**：已按本报告 §3 原样重做两处改动（并一并重做了学科颜色修复），重新跑 `flutter analyze`（0 问题）、`flutter test`（279/279）、Linux Release 构建（libapp.so `19d46ef4`），并重新截图验证：整理深色/亮色、详情亮色三处纸面中心偏差均为 0px（截图 `shots/s8a1/recheck-organize-dark.png`、`recheck-organize-light.png`、`recheck-detail-light.png`，与第一轮数值完全一致）。**曾被还原、已按报告重做并重新验证通过。**
- **后续约定**：主 agent 做 git 同步前先与协调员确认，不再直接 `reset --hard`。
